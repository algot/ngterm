//! The app's ssh keys: [`generate`] makes an ed25519 key, [`import`] reads one the user brings (OpenSSH, PKCS#1 or
//! PKCS#8, with its passphrase), [`load`] turns the bytes a [`crate::KeyVault`] hands over back into a key for a
//! connection, and [`export`] writes a stored key out for the user to carry to another install, under a passphrase
//! unless they chose none.
//!
//! The private bytes the app stores are always an unencrypted OpenSSH key: the platform protects them (the Android
//! Keystore wraps them, the iOS Keychain holds them), so an imported key loses its passphrase here, once. Every private
//! byte this module reads or writes on its own side is wiped once used ([`zeroize::Zeroizing`]); the bytes returned in
//! a [`KeyPair`] are the app's to store and wipe.

use ::russh::keys::ssh_key::rand_core::TryCryptoRng;
use ::russh::keys::ssh_key::{Cipher, Kdf, KdfAlg, LineEnding};
use ::russh::keys::{Algorithm, HashAlg, PrivateKey, decode_secret_key};
use zeroize::Zeroizing;

/// The bcrypt-pbkdf rounds of an export: what `ssh-keygen` writes by default since OpenSSH 9.4.
const EXPORT_KDF_ROUNDS: u32 = 24;

/// The most bcrypt-pbkdf rounds an imported key may ask for: a file can name any count, and each is real work.
const MAX_IMPORT_KDF_ROUNDS: u32 = 1024;

/// A private key as the app stores it, with what it shows of it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeyPair {
    /// The unencrypted OpenSSH private key, for the app to keep with the platform (the Android Keystore, the iOS
    /// Keychain) and hand back through [`crate::KeyVault::load`].
    pub private_key: Vec<u8>,
    /// The public key as an `authorized_keys` line (`ssh-ed25519 AAAA… comment`).
    pub authorized_key: String,
    /// The public key's OpenSSH `SHA256:` fingerprint.
    pub fingerprint: String,
}

/// What protects an exported private key.
#[derive(Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ExportProtection {
    /// OpenSSH's own encryption (aes256-ctr under a bcrypt-pbkdf key) with the user's passphrase, as `ssh-keygen -p`
    /// writes it.
    Passphrase { passphrase: String },
    /// Nothing: whoever reads the export has the key. Only on the user's explicit, warned choice.
    Unprotected,
}

impl std::fmt::Debug for ExportProtection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Passphrase { .. } => "Passphrase",
            Self::Unprotected => "Unprotected",
        })
    }
}

/// Why a key could not be made or read.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum KeyError {
    /// The key is encrypted and no passphrase was given.
    #[error("the key is protected by a passphrase")]
    PassphraseRequired,
    /// The passphrase does not open the key.
    #[error("the passphrase is wrong")]
    WrongPassphrase,
    /// The bytes are not a private key this app can use.
    #[error("{reason}")]
    Invalid { reason: String },
}

/// A new ed25519 key whose public half carries `comment`.
///
/// # Errors
///
/// [`KeyError::Invalid`] if the key can't be generated or encoded (the system's random source failed).
pub fn generate(comment: &str) -> Result<KeyPair, KeyError> {
    let mut key = PrivateKey::random(&mut ::russh::keys::key::safe_rng(), Algorithm::Ed25519).map_err(invalid)?;
    key.set_comment(comment);
    pair(&key)
}

/// The key in `bytes` (OpenSSH, PKCS#1 or PKCS#8 PEM), opened with `passphrase` when it is encrypted, re-encoded as
/// the unencrypted OpenSSH key the app stores.
///
/// # Errors
///
/// [`KeyError::PassphraseRequired`] for an encrypted key with no passphrase, [`KeyError::WrongPassphrase`] when the
/// passphrase doesn't open it, [`KeyError::Invalid`] for anything that isn't a usable private key.
pub fn import(bytes: &[u8], passphrase: Option<&str>) -> Result<KeyPair, KeyError> {
    let text = std::str::from_utf8(bytes).map_err(|_| KeyError::Invalid {
        reason: "the key is not text".to_owned(),
    })?;
    let passphrase = passphrase.filter(|passphrase| !passphrase.is_empty());
    refuse_excessive_kdf(text)?;
    let key = decode_secret_key(text, passphrase).map_err(|error| match error {
        ::russh::keys::Error::KeyIsEncrypted => KeyError::PassphraseRequired,
        _ if is_encrypted(text) => {
            if passphrase.is_some() {
                KeyError::WrongPassphrase
            } else {
                KeyError::PassphraseRequired
            }
        }
        error => invalid(error),
    })?;
    if key.is_encrypted() {
        return Err(KeyError::PassphraseRequired);
    }
    pair(&key)
}

/// The key a [`crate::KeyVault`] handed over, as [`generate`] or [`import`] produced it. The caller wipes `bytes`
/// (holds them in [`zeroize::Zeroizing`]); the key wipes itself when dropped.
///
/// # Errors
///
/// [`KeyError`] as [`import`] gives it with no passphrase.
pub fn load(bytes: &[u8]) -> Result<PrivateKey, KeyError> {
    let text = std::str::from_utf8(bytes).map_err(|_| KeyError::Invalid {
        reason: "the key is not text".to_owned(),
    })?;
    let key = decode_secret_key(text, None).map_err(|error| match error {
        ::russh::keys::Error::KeyIsEncrypted => KeyError::PassphraseRequired,
        error => invalid(error),
    })?;
    if key.is_encrypted() {
        return Err(KeyError::PassphraseRequired);
    }
    Ok(key)
}

/// The stored key in `bytes` (as [`generate`] or [`import`] produced it) as an OpenSSH private key file, encrypted
/// under `protection`'s passphrase or, on [`ExportProtection::Unprotected`], as it is stored. [`import`] reads it
/// back. The passphrase and this side's copies of the key are wiped; the caller wipes `bytes` and what it gets.
///
/// # Errors
///
/// [`KeyError::Invalid`] for an empty passphrase, bytes that aren't a stored key, or a failed encryption (the
/// system's random source failed); [`KeyError::PassphraseRequired`] for bytes that are an encrypted key, which is
/// never a stored one.
pub fn export(bytes: &[u8], protection: ExportProtection) -> Result<Zeroizing<String>, KeyError> {
    let passphrase = match protection {
        ExportProtection::Passphrase { passphrase } => Some(Zeroizing::new(passphrase)),
        ExportProtection::Unprotected => None,
    };
    if passphrase.as_ref().is_some_and(|passphrase| passphrase.is_empty()) {
        return Err(KeyError::Invalid {
            reason: "the passphrase is empty".to_owned(),
        });
    }
    let key = load(bytes)?;
    let key = match passphrase {
        Some(passphrase) => encrypt(&key, &mut ::russh::keys::key::safe_rng(), passphrase.as_bytes())?,
        None => key,
    };
    key.to_openssh(LineEnding::LF).map_err(invalid)
}

fn encrypt<R: TryCryptoRng>(key: &PrivateKey, rng: &mut R, passphrase: &[u8]) -> Result<PrivateKey, KeyError> {
    let checkint = rng.try_next_u32().map_err(|_| invalid("the random source failed"))?;
    let mut kdf = Kdf::new(KdfAlg::Bcrypt, rng).map_err(invalid)?;
    if let Kdf::Bcrypt { rounds, .. } = &mut kdf {
        *rounds = EXPORT_KDF_ROUNDS;
    }
    key.encrypt_with(Cipher::Aes256Ctr, kdf, checkint, passphrase)
        .map_err(invalid)
}

fn refuse_excessive_kdf(text: &str) -> Result<(), KeyError> {
    let rounds = PrivateKey::from_openssh(text).ok().and_then(|key| match key.kdf() {
        Kdf::Bcrypt { rounds, .. } => Some(*rounds),
        _ => None,
    });
    match rounds {
        Some(rounds) if rounds > MAX_IMPORT_KDF_ROUNDS => Err(KeyError::Invalid {
            reason: format!(
                "the key's passphrase protection asks for {rounds} rounds, more than the {MAX_IMPORT_KDF_ROUNDS} \
                 this app works through"
            ),
        }),
        _ => Ok(()),
    }
}

/// Whether the PEM text holds an encrypted key: an OpenSSH key with a cipher, or an encrypted PKCS#8 or PKCS#5 one.
fn is_encrypted(text: &str) -> bool {
    PrivateKey::from_openssh(text).is_ok_and(|key| key.is_encrypted())
        || text.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----")
        || text.contains("Proc-Type: 4,ENCRYPTED")
}

fn pair(key: &PrivateKey) -> Result<KeyPair, KeyError> {
    let private = key.to_openssh(LineEnding::LF).map_err(invalid)?;
    let authorized_key = key.public_key().to_openssh().map_err(invalid)?;
    Ok(KeyPair {
        private_key: private.as_bytes().to_vec(),
        authorized_key,
        fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
    })
}

fn invalid(error: impl std::fmt::Display) -> KeyError {
    KeyError::Invalid {
        reason: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use ::russh::keys::PublicKey;

    use super::*;

    fn encrypted(key: &PrivateKey, passphrase: &str) -> Vec<u8> {
        let mut rng = ::russh::keys::key::safe_rng();
        let locked = key.encrypt(&mut rng, passphrase).unwrap();
        locked.to_openssh(LineEnding::LF).unwrap().as_bytes().to_vec()
    }

    #[test]
    fn a_generated_key_is_ed25519_and_its_parts_agree() {
        let pair = generate("phone").unwrap();

        let key = load(&pair.private_key).unwrap();
        assert_eq!(key.algorithm(), Algorithm::Ed25519);
        assert!(pair.authorized_key.starts_with("ssh-ed25519 "));
        assert!(pair.authorized_key.ends_with(" phone"));
        let public = PublicKey::from_openssh(&pair.authorized_key).unwrap();
        assert_eq!(public.key_data(), key.public_key().key_data());
        assert_eq!(pair.fingerprint, key.fingerprint(HashAlg::Sha256).to_string());
        assert!(pair.fingerprint.starts_with("SHA256:"));
    }

    #[test]
    fn two_generated_keys_differ() {
        assert_ne!(generate("a").unwrap().private_key, generate("a").unwrap().private_key);
    }

    #[test]
    fn an_unencrypted_key_imports_as_it_is() {
        let pair = generate("laptop").unwrap();

        let imported = import(&pair.private_key, None).unwrap();

        assert_eq!(imported, pair);
    }

    #[test]
    fn an_encrypted_key_imports_with_its_passphrase_and_is_stored_unencrypted() {
        let pair = generate("laptop").unwrap();
        let key = load(&pair.private_key).unwrap();

        let imported = import(&encrypted(&key, "secret"), Some("secret")).unwrap();

        assert_eq!(imported.authorized_key, pair.authorized_key);
        assert!(!load(&imported.private_key).unwrap().is_encrypted());
    }

    #[test]
    fn an_encrypted_key_needs_its_passphrase() {
        let key = load(&generate("x").unwrap().private_key).unwrap();
        let locked = encrypted(&key, "secret");

        assert_eq!(import(&locked, None), Err(KeyError::PassphraseRequired));
        assert_eq!(import(&locked, Some("")), Err(KeyError::PassphraseRequired));
        assert_eq!(import(&locked, Some("wrong")), Err(KeyError::WrongPassphrase));
        assert_eq!(load(&locked).err(), Some(KeyError::PassphraseRequired));
    }

    fn locked(passphrase: &str) -> ExportProtection {
        ExportProtection::Passphrase {
            passphrase: passphrase.to_owned(),
        }
    }

    #[test]
    fn an_export_under_a_passphrase_is_an_encrypted_openssh_key_that_imports_back_as_the_same_key() {
        let pair = generate("phone").unwrap();

        let exported = export(&pair.private_key, locked("correct horse")).unwrap();

        assert!(exported.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----\n"));
        let parsed = PrivateKey::from_openssh(exported.as_str()).unwrap();
        assert!(parsed.is_encrypted());
        assert_eq!(parsed.cipher().as_str(), "aes256-ctr");
        assert!(matches!(parsed.kdf(), Kdf::Bcrypt { salt, rounds: 24 } if salt.len() == 16));
        let imported = import(exported.as_bytes(), Some("correct horse")).unwrap();
        assert_eq!(imported.authorized_key, pair.authorized_key);
        assert_eq!(imported.fingerprint, pair.fingerprint);
        assert_eq!(
            load(&imported.private_key).unwrap().key_data(),
            load(&pair.private_key).unwrap().key_data()
        );
    }

    #[test]
    fn an_import_refuses_a_key_that_asks_for_excessive_kdf_work() {
        let pair = generate("phone").unwrap();
        let key = load(&pair.private_key).unwrap();
        let salt = vec![7; 16];
        let within = key
            .encrypt_with(Cipher::Aes256Ctr, Kdf::Bcrypt { salt, rounds: 2 }, 1, "secret")
            .unwrap();
        let mut bytes = within.to_bytes().unwrap().to_vec();
        let rounds = bytes.windows(4).position(|window| window == [0, 0, 0, 2]).unwrap();
        bytes[rounds..rounds + 4].copy_from_slice(&u32::MAX.to_be_bytes());
        let hostile = PrivateKey::from_bytes(&bytes)
            .unwrap()
            .to_openssh(LineEnding::LF)
            .unwrap();

        let refused = import(hostile.as_bytes(), Some("secret"));

        assert_eq!(
            refused,
            Err(KeyError::Invalid {
                reason: "the key's passphrase protection asks for 4294967295 rounds, more than the 1024 this app \
                         works through"
                    .to_owned()
            })
        );
        let within = within.to_openssh(LineEnding::LF).unwrap();
        assert_eq!(
            import(within.as_bytes(), Some("secret")).unwrap().fingerprint,
            pair.fingerprint
        );
    }

    #[test]
    fn an_export_opens_only_with_its_passphrase() {
        let pair = generate("phone").unwrap();

        let exported = export(&pair.private_key, locked("correct horse")).unwrap();

        assert_eq!(
            import(exported.as_bytes(), Some("wrong")),
            Err(KeyError::WrongPassphrase)
        );
        assert_eq!(import(exported.as_bytes(), None), Err(KeyError::PassphraseRequired));
        assert_eq!(load(exported.as_bytes()).err(), Some(KeyError::PassphraseRequired));
    }

    #[test]
    fn two_exports_of_a_key_under_one_passphrase_differ() {
        let pair = generate("phone").unwrap();

        let first = export(&pair.private_key, locked("secret")).unwrap();
        let second = export(&pair.private_key, locked("secret")).unwrap();

        assert_ne!(*first, *second);
    }

    #[test]
    fn an_unprotected_export_is_the_stored_key() {
        let pair = generate("phone").unwrap();

        let exported = export(&pair.private_key, ExportProtection::Unprotected).unwrap();

        assert_eq!(exported.as_bytes(), pair.private_key.as_slice());
        assert_eq!(import(exported.as_bytes(), None).unwrap(), pair);
    }

    #[test]
    fn an_export_refuses_an_empty_passphrase_and_what_is_not_a_stored_key() {
        let pair = generate("phone").unwrap();

        assert_eq!(
            export(&pair.private_key, locked("")),
            Err(KeyError::Invalid {
                reason: "the passphrase is empty".to_owned()
            })
        );
        assert!(matches!(
            export(b"hello", locked("secret")),
            Err(KeyError::Invalid { .. })
        ));
        let exported = export(&pair.private_key, locked("secret")).unwrap();
        assert_eq!(
            export(exported.as_bytes(), locked("again")),
            Err(KeyError::PassphraseRequired)
        );
    }

    #[test]
    fn an_export_protection_never_prints_its_passphrase() {
        assert_eq!(format!("{:?}", locked("hunter2")), "Passphrase");
        assert_eq!(format!("{:?}", ExportProtection::Unprotected), "Unprotected");
    }

    /// `ssh-keygen -y` prints the public half of a private key file it can read, so it accepting the export (with
    /// its passphrase) and printing the app's public key is OpenSSH itself reading the format.
    #[cfg(unix)]
    #[test]
    fn ssh_keygen_reads_an_export_with_its_passphrase() {
        use std::io::Write as _;
        use std::process::Command;

        if Command::new("ssh-keygen").arg("-?").output().is_err() {
            eprintln!("skipped: no ssh-keygen on this machine");
            return;
        }
        let pair = generate("phone").unwrap();
        let public = |output: std::process::Output| {
            let text = String::from_utf8(output.stdout).unwrap();
            PublicKey::from_openssh(text.trim()).map(|key| key.key_data().clone())
        };
        let expected = PublicKey::from_openssh(&pair.authorized_key).unwrap();
        let keygen = |exported: &str, passphrase: &str| {
            let mut file = tempfile::NamedTempFile::new().unwrap();
            file.write_all(exported.as_bytes()).unwrap();
            file.flush().unwrap();
            Command::new("ssh-keygen")
                .args(["-y", "-P", passphrase, "-f"])
                .arg(file.path())
                .output()
                .unwrap()
        };

        let exported = export(&pair.private_key, locked("correct horse")).unwrap();

        let read = keygen(&exported, "correct horse");
        assert!(read.status.success(), "{}", String::from_utf8_lossy(&read.stderr));
        assert_eq!(public(read).unwrap(), *expected.key_data());
        assert!(!keygen(&exported, "wrong").status.success());
        let open = export(&pair.private_key, ExportProtection::Unprotected).unwrap();
        assert_eq!(public(keygen(&open, "")).unwrap(), *expected.key_data());
    }

    #[test]
    fn a_pkcs8_key_imports() {
        let pkcs8 = "-----BEGIN PRIVATE KEY-----\n\
                     MC4CAQAwBQYDK2VwBCIEINTuctv5E1hK1bbY8fdp+K06/nwoy/HU++CXqI9EdVhC\n\
                     -----END PRIVATE KEY-----\n";

        let imported = import(pkcs8.as_bytes(), None).unwrap();

        assert!(imported.authorized_key.starts_with("ssh-ed25519 "));
    }

    #[test]
    fn what_is_not_a_key_is_invalid() {
        assert!(matches!(import(b"hello", None), Err(KeyError::Invalid { .. })));
        assert!(matches!(import(&[0xff, 0xfe], None), Err(KeyError::Invalid { .. })));
        assert!(matches!(load(b"hello"), Err(KeyError::Invalid { .. })));
    }
}
