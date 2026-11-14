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
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use pkcs8::EncryptedPrivateKeyInfoRef;
use pkcs8::der::Decode as _;
use pkcs8::pkcs5::{EncryptionScheme, pbes2};
use unicode_segmentation::UnicodeSegmentation;
use zeroize::Zeroizing;

/// The fewest characters an export's passphrase may have: it is all that slows guessing at a lost export.
pub const EXPORT_PASSPHRASE_MIN_CHARS: u32 = 8;

/// The bcrypt-pbkdf rounds of an export: what `ssh-keygen` writes by default since OpenSSH 9.4.
const EXPORT_KDF_ROUNDS: u32 = 24;

/// The most bcrypt-pbkdf rounds an imported key may ask for: a file can name any count, and each is real work.
const MAX_IMPORT_KDF_ROUNDS: u32 = 1024;

/// The most PBKDF2 iterations an imported PKCS#8 key may ask for: RFC 8018's count for especially critical keys.
const MAX_IMPORT_PBKDF2_ITERATIONS: u32 = 10_000_000;

/// The most memory an imported key's scrypt or Argon2 may ask for, in KiB: what a phone can spare.
const MAX_IMPORT_KDF_MEMORY_KIB: u64 = 128 * 1024;

/// The most scrypt parallelization an imported PKCS#8 key may ask for: each unit is one more pass over the memory.
const MAX_IMPORT_SCRYPT_PARALLELIZATION: u16 = 16;

/// The most Argon2 passes an imported PPK key may ask for.
const MAX_IMPORT_ARGON2_PASSES: u32 = 256;

const PPK_HEADER: &str = "PuTTY-User-Key-File-";
const PPK_CIPHER: &str = "aes256-cbc";
const OPENSSH_ARMOR: &str = "-----BEGIN OPENSSH PRIVATE KEY-----";
const RSA_ARMOR: &str = "-----BEGIN RSA PRIVATE KEY-----";
const ENCRYPTED_PKCS8_ARMOR: &str = "-----BEGIN ENCRYPTED PRIVATE KEY-----";
const ARMORS: [&str; 5] = [
    OPENSSH_ARMOR,
    RSA_ARMOR,
    ENCRYPTED_PKCS8_ARMOR,
    "-----BEGIN PRIVATE KEY-----",
    "-----BEGIN EC PRIVATE KEY-----",
];
const PKCS5_IV: &str = "DEK-Info: AES-128-CBC,";
const PKCS5_ENCRYPTED: &str = "Proc-Type: 4,ENCRYPTED";
const PEM_WIDTH: usize = 70;

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
    /// An export's passphrase has fewer than `minimum` characters, counted as a person counts them.
    #[error("the passphrase needs at least {minimum} characters")]
    PassphraseTooShort { minimum: u32 },
    /// The bytes are not a private key this app can use.
    #[error("{reason}")]
    Invalid { reason: String },
}

impl KeyError {
    /// The error's name, for the log.
    #[must_use]
    pub fn class(&self) -> &'static str {
        match self {
            Self::PassphraseRequired => "passphrase-required",
            Self::WrongPassphrase => "wrong-passphrase",
            Self::PassphraseTooShort { .. } => "passphrase-too-short",
            Self::Invalid { .. } => "invalid",
        }
    }
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

/// The key in `bytes` (OpenSSH, PKCS#1 or PKCS#8 PEM, or a PPK file), opened with `passphrase` when it is encrypted,
/// re-encoded as the unencrypted OpenSSH key the app stores. A key whose passphrase protection asks for more work or
/// memory than the caps above is refused before any of it is done.
///
/// # Errors
///
/// [`KeyError::PassphraseRequired`] for an encrypted key with no passphrase, [`KeyError::WrongPassphrase`] when the
/// passphrase doesn't open it, [`KeyError::Invalid`] for anything that isn't a usable private key or asks for
/// excessive key derivation.
pub fn import(bytes: &[u8], passphrase: Option<&str>) -> Result<KeyPair, KeyError> {
    let text = std::str::from_utf8(bytes).map_err(|_| KeyError::Invalid {
        reason: "the key is not text".to_owned(),
    })?;
    let passphrase = passphrase.filter(|passphrase| !passphrase.is_empty());
    let vetted = vetted(text)?;
    let key = decode_secret_key(&vetted, passphrase).map_err(|error| match error {
        ::russh::keys::Error::KeyIsEncrypted => KeyError::PassphraseRequired,
        _ if is_encrypted(&vetted) || text.contains(PKCS5_ENCRYPTED) => {
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
/// [`KeyError::PassphraseTooShort`] for a passphrase under [`EXPORT_PASSPHRASE_MIN_CHARS`] characters (grapheme
/// clusters, not bytes); [`KeyError::Invalid`] for bytes that aren't a stored key or a failed encryption (the system's
/// random source failed); [`KeyError::PassphraseRequired`] for bytes that are an encrypted key, which is never a
/// stored one.
pub fn export(bytes: &[u8], protection: ExportProtection) -> Result<Zeroizing<String>, KeyError> {
    let passphrase = match protection {
        ExportProtection::Passphrase { passphrase } => Some(Zeroizing::new(passphrase)),
        ExportProtection::Unprotected => None,
    };
    if passphrase
        .as_ref()
        .is_some_and(|passphrase| export_passphrase_too_short(passphrase))
    {
        return Err(KeyError::PassphraseTooShort {
            minimum: EXPORT_PASSPHRASE_MIN_CHARS,
        });
    }
    let key = load(bytes)?;
    let key = match passphrase {
        Some(passphrase) => encrypt(&key, &mut ::russh::keys::key::safe_rng(), passphrase.as_bytes())?,
        None => key,
    };
    key.to_openssh(LineEnding::LF).map_err(invalid)
}

/// Whether [`export`] refuses `passphrase` as under [`EXPORT_PASSPHRASE_MIN_CHARS`] characters: the one count of
/// them, for an app to check with before it asks for the export.
#[must_use]
pub fn export_passphrase_too_short(passphrase: &str) -> bool {
    passphrase
        .graphemes(true)
        .take(EXPORT_PASSPHRASE_MIN_CHARS as usize)
        .count()
        < EXPORT_PASSPHRASE_MIN_CHARS as usize
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

/// `text` as [`decode_secret_key`] is to read it, once what it asks of a passphrase's key derivation is within the
/// caps. A PEM is rewritten from the bytes that were checked, so the lenient reader there decodes exactly those.
fn vetted(text: &str) -> Result<Zeroizing<String>, KeyError> {
    if text.trim().starts_with(PPK_HEADER) {
        refuse_excessive_argon2(text)?;
        return Ok(Zeroizing::new(text.to_owned()));
    }
    let pem = Pem::read(text)?;
    pem.refuse_excessive_kdf()?;
    Ok(pem.canonical())
}

/// A PEM private key as russh's `decode_secret_key` reads one: the last armor named, the legacy cipher line under
/// it, and the bytes of every base64 line up to the first END.
struct Pem<'a> {
    armor: &'a str,
    legacy_iv: Option<&'a str>,
    der: Zeroizing<Vec<u8>>,
}

impl<'a> Pem<'a> {
    fn read(text: &'a str) -> Result<Self, KeyError> {
        let mut armor = None;
        let mut legacy_iv = None;
        let mut body = Zeroizing::new(String::with_capacity(text.len()));
        for line in text.lines() {
            if armor.is_some() {
                if line.starts_with("-----END ") {
                    break;
                }
                if line.bytes().all(is_base64) {
                    body.push_str(line);
                } else if line.starts_with(PKCS5_IV) {
                    legacy_iv = Some(line);
                }
            }
            if ARMORS.contains(&line) {
                armor = Some(line);
                legacy_iv = None;
            }
        }
        let armor = armor.ok_or_else(|| invalid(::russh::keys::Error::CouldNotReadKey))?;
        let der = Zeroizing::new(STANDARD.decode(body.as_bytes()).map_err(invalid)?);
        Ok(Self { armor, legacy_iv, der })
    }

    fn refuse_excessive_kdf(&self) -> Result<(), KeyError> {
        match self.armor {
            RSA_ARMOR => Ok(()),
            OPENSSH_ARMOR => match PrivateKey::from_bytes(&self.der).as_ref().map(PrivateKey::kdf) {
                Ok(Kdf::Bcrypt { rounds, .. }) if *rounds > MAX_IMPORT_KDF_ROUNDS => {
                    Err(excessive(format_args!("{rounds} rounds"), MAX_IMPORT_KDF_ROUNDS))
                }
                _ => Ok(()),
            },
            // russh opens any of the PKCS#8 armors as an encrypted key once a passphrase is given
            _ => match EncryptedPrivateKeyInfoRef::from_der(&self.der) {
                Ok(encrypted) => refuse_excessive_pbes(&encrypted.encryption_algorithm),
                Err(_) => Ok(()),
            },
        }
    }

    fn canonical(&self) -> Zeroizing<String> {
        let body = Zeroizing::new(STANDARD.encode(&self.der));
        let mut text = Zeroizing::new(String::with_capacity(body.len() + body.len() / PEM_WIDTH + 256));
        text.push_str(self.armor);
        text.push('\n');
        if let Some(iv) = self.legacy_iv {
            text.push_str(iv);
            text.push('\n');
        }
        let mut rest = body.as_str();
        while !rest.is_empty() {
            let (line, tail) = rest.split_at(rest.len().min(PEM_WIDTH));
            text.push_str(line);
            text.push('\n');
            rest = tail;
        }
        text.push_str(&self.armor.replacen("BEGIN", "END", 1));
        text.push('\n');
        text
    }
}

const fn is_base64(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'+' | b'=')
}

fn refuse_excessive_pbes(scheme: &EncryptionScheme) -> Result<(), KeyError> {
    // PBES1 is never decrypted: pkcs5 refuses it
    let EncryptionScheme::Pbes2(parameters) = scheme else {
        return Ok(());
    };
    match &parameters.kdf {
        pbes2::Kdf::Pbkdf2(pbkdf2) if pbkdf2.iteration_count > MAX_IMPORT_PBKDF2_ITERATIONS => Err(excessive(
            format_args!("{} iterations", pbkdf2.iteration_count),
            MAX_IMPORT_PBKDF2_ITERATIONS,
        )),
        pbes2::Kdf::Scrypt(scrypt) => {
            // scrypt holds 128 bytes per unit of (N + p)·r
            let blocks = scrypt.cost_parameter.saturating_add(u64::from(scrypt.parallelization));
            let memory_kib = blocks.saturating_mul(u64::from(scrypt.block_size)) / 8;
            if memory_kib > MAX_IMPORT_KDF_MEMORY_KIB {
                Err(excessive_memory(memory_kib))
            } else if scrypt.parallelization > MAX_IMPORT_SCRYPT_PARALLELIZATION {
                Err(excessive(
                    format_args!("a parallelization of {}", scrypt.parallelization),
                    MAX_IMPORT_SCRYPT_PARALLELIZATION,
                ))
            } else if scrypt.cost_parameter < 2 || !scrypt.cost_parameter.is_power_of_two() {
                // pkcs5 panics on a cost of 0
                Err(KeyError::Invalid {
                    reason: format!(
                        "the key's passphrase protection has a scrypt cost of {}, which is not a power of two above 1",
                        scrypt.cost_parameter
                    ),
                })
            } else {
                Ok(())
            }
        }
        _ => Ok(()),
    }
}

/// ssh-key's PPK reader keeps the last value of a repeated header, so every line that names one is held to the cap.
fn refuse_excessive_argon2(text: &str) -> Result<(), KeyError> {
    for line in text.lines() {
        let Some((name, value)) = line.split_once(": ") else {
            continue;
        };
        let Ok(value) = value.parse::<u32>() else {
            continue;
        };
        match name {
            "Argon2-Memory" if u64::from(value) > MAX_IMPORT_KDF_MEMORY_KIB => {
                return Err(excessive_memory(u64::from(value)));
            }
            "Argon2-Passes" if value > MAX_IMPORT_ARGON2_PASSES => {
                return Err(excessive(format_args!("{value} passes"), MAX_IMPORT_ARGON2_PASSES));
            }
            _ => {}
        }
    }
    Ok(())
}

fn excessive(asked: impl std::fmt::Display, most: impl std::fmt::Display) -> KeyError {
    KeyError::Invalid {
        reason: format!(
            "the key's passphrase protection asks for {asked}, more than the {most} this app works through"
        ),
    }
}

fn excessive_memory(kib: u64) -> KeyError {
    excessive(
        format_args!("{kib} KiB of memory"),
        format_args!("{MAX_IMPORT_KDF_MEMORY_KIB} KiB"),
    )
}

/// Whether the text holds an encrypted key: an OpenSSH key with a cipher, an encrypted PKCS#8 one, or a PPK file
/// under the cipher its reader decrypts.
fn is_encrypted(text: &str) -> bool {
    if text.starts_with(PPK_HEADER) {
        // ssh-key's PPK reader keeps the last value of a repeated header
        return text
            .lines()
            .filter_map(|line| line.strip_prefix("Encryption: "))
            .next_back()
            == Some(PPK_CIPHER);
    }
    PrivateKey::from_openssh(text).is_ok_and(|key| key.is_encrypted()) || text.contains(ENCRYPTED_PKCS8_ARMOR)
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

    fn with_excessive_rounds() -> String {
        let key = load(&generate("phone").unwrap().private_key).unwrap();
        let salt = vec![7; 16];
        let within = key
            .encrypt_with(Cipher::Aes256Ctr, Kdf::Bcrypt { salt, rounds: 2 }, 1, "secret")
            .unwrap();
        let mut bytes = within.to_bytes().unwrap().to_vec();
        let rounds = bytes.windows(4).position(|window| window == [0, 0, 0, 2]).unwrap();
        bytes[rounds..rounds + 4].copy_from_slice(&u32::MAX.to_be_bytes());
        let hostile = PrivateKey::from_bytes(&bytes).unwrap();
        hostile.to_openssh(LineEnding::LF).unwrap().to_string()
    }

    fn rewrapped(pem: &str, width: usize) -> String {
        let lines: Vec<&str> = pem.lines().collect();
        let body = lines[1..lines.len() - 1].concat();
        let mut text = format!("{}\n", lines[0]);
        for line in body.as_bytes().chunks(width) {
            text.push_str(std::str::from_utf8(line).unwrap());
            text.push('\n');
        }
        format!("{text}{}\n", lines[lines.len() - 1])
    }

    /// The ways a PEM can differ from what a strict reader takes while russh still reads the key in it.
    fn loosened(pem: &str) -> [String; 4] {
        let (first, rest) = pem.split_once('\n').unwrap();
        [
            format!("{pem}trailing words\n"),
            format!("{first}\nx y\n{rest}"),
            rewrapped(pem, 33),
            format!("a note before the key\n{pem}"),
        ]
    }

    #[test]
    fn an_import_refuses_excessive_kdf_work_however_loosely_the_key_is_written() {
        let hostile = with_excessive_rounds();

        for text in loosened(&hostile) {
            assert_eq!(
                import(text.as_bytes(), Some("secret")),
                Err(KeyError::Invalid {
                    reason: "the key's passphrase protection asks for 4294967295 rounds, more than the 1024 this \
                             app works through"
                        .to_owned()
                }),
                "{text}"
            );
        }
    }

    #[test]
    fn a_loosely_written_key_imports_and_says_when_its_passphrase_is_wrong() {
        let pair = generate("laptop").unwrap();
        let locked = String::from_utf8(encrypted(&load(&pair.private_key).unwrap(), "secret")).unwrap();

        for text in loosened(&locked) {
            assert_eq!(
                import(text.as_bytes(), Some("secret")).unwrap().fingerprint,
                pair.fingerprint,
                "{text}"
            );
            assert_eq!(import(text.as_bytes(), Some("wrong")), Err(KeyError::WrongPassphrase));
            assert_eq!(import(text.as_bytes(), None), Err(KeyError::PassphraseRequired));
        }
    }

    fn pkcs8_under(kdf: pbes2::Kdf, armor: &str) -> String {
        use pkcs8::der::Encode as _;
        use pkcs8::der::asn1::OctetString;

        let encrypted = pkcs8::EncryptedPrivateKeyInfoOwned {
            encryption_algorithm: EncryptionScheme::Pbes2(pbes2::Parameters {
                kdf,
                encryption: pbes2::EncryptionScheme::Aes256Cbc { iv: [3; 16] },
            }),
            encrypted_data: OctetString::new(vec![5; 48]).unwrap(),
        };
        let body = STANDARD.encode(encrypted.to_der().unwrap());
        format!("-----BEGIN {armor}-----\n{body}\n-----END {armor}-----\n")
    }

    fn pbkdf2(iterations: u32) -> pbes2::Kdf {
        pbes2::Pbkdf2Params::hmac_sha256(iterations, &[7; 16]).unwrap().into()
    }

    fn scrypt(cost: u64, block_size: u16, parallelization: u16) -> pbes2::Kdf {
        pbes2::Kdf::Scrypt(pbes2::ScryptParams {
            salt: pbes2::Salt::new([7; 16]).unwrap(),
            cost_parameter: cost,
            block_size,
            parallelization,
            key_length: None,
        })
    }

    fn refusal(text: &str) -> String {
        match import(text.as_bytes(), Some("secret")) {
            Err(KeyError::Invalid { reason }) => reason,
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn an_import_refuses_a_pkcs8_key_that_asks_for_excessive_kdf_work_under_either_armor() {
        for armor in ["ENCRYPTED PRIVATE KEY", "PRIVATE KEY"] {
            assert_eq!(
                refusal(&pkcs8_under(pbkdf2(10_000_001), armor)),
                "the key's passphrase protection asks for 10000001 iterations, more than the 10000000 this app \
                 works through"
            );
            assert_eq!(
                refusal(&pkcs8_under(scrypt(1 << 40, 1, 1), armor)),
                "the key's passphrase protection asks for 137438953472 KiB of memory, more than the 131072 KiB this \
                 app works through"
            );
            assert_eq!(
                refusal(&pkcs8_under(scrypt(u64::MAX, u16::MAX, 1), armor)),
                "the key's passphrase protection asks for 2305843009213693951 KiB of memory, more than the 131072 \
                 KiB this app works through"
            );
            for cost in [0, 1, 3, (1 << 14) + 1] {
                assert_eq!(
                    refusal(&pkcs8_under(scrypt(cost, 8, 1), armor)),
                    format!(
                        "the key's passphrase protection has a scrypt cost of {cost}, which is not a power of two \
                         above 1"
                    )
                );
            }
            assert_eq!(
                refusal(&pkcs8_under(scrypt(1 << 14, 8, 17), armor)),
                "the key's passphrase protection asks for a parallelization of 17, more than the 16 this app works \
                 through"
            );
        }
    }

    #[test]
    fn a_pkcs8_key_at_the_caps_is_worked_through() {
        // garbage under a passphrase: the derivation runs and the decryption fails, which is not a refusal
        for kdf in [pbkdf2(2), scrypt(1 << 4, 8, 16)] {
            assert_eq!(
                import(pkcs8_under(kdf, "ENCRYPTED PRIVATE KEY").as_bytes(), Some("secret")),
                Err(KeyError::WrongPassphrase)
            );
        }
        let at_the_memory_cap = pkcs8_under(scrypt(1 << 17, 8, 0), "ENCRYPTED PRIVATE KEY");
        assert_eq!(Pem::read(&at_the_memory_cap).unwrap().refuse_excessive_kdf(), Ok(()));
        let over_it_by_parallelization = pkcs8_under(scrypt(1 << 17, 8, 1), "ENCRYPTED PRIVATE KEY");
        assert!(refusal(&over_it_by_parallelization).contains("131073 KiB of memory"));
        let at_the_iteration_cap = pkcs8_under(pbkdf2(10_000_000), "ENCRYPTED PRIVATE KEY");
        assert_eq!(Pem::read(&at_the_iteration_cap).unwrap().refuse_excessive_kdf(), Ok(()));
    }

    #[test]
    fn an_encrypted_pkcs8_key_imports_with_its_passphrase() {
        let pair = generate("laptop").unwrap();
        let mut pem = Vec::new();
        ::russh::keys::encode_pkcs8_pem_encrypted(&load(&pair.private_key).unwrap(), b"secret", 64, &mut pem).unwrap();

        assert_eq!(import(&pem, Some("secret")).unwrap().fingerprint, pair.fingerprint);
        assert_eq!(import(&pem, Some("wrong")), Err(KeyError::WrongPassphrase));
        assert_eq!(import(&pem, None), Err(KeyError::PassphraseRequired));
    }

    /// A throwaway key from `openssl genrsa -traditional -aes-128-cbc`, its passphrase `secret`.
    const LEGACY_RSA: &str = include_str!("../tests/fixtures/legacy-rsa-aes128.pem");

    #[test]
    fn a_legacy_encrypted_rsa_key_imports_with_its_passphrase() {
        let imported = import(LEGACY_RSA.as_bytes(), Some("secret")).unwrap();

        assert!(imported.authorized_key.starts_with("ssh-rsa "));
        assert_eq!(import(LEGACY_RSA.as_bytes(), None), Err(KeyError::PassphraseRequired));
        assert_eq!(
            import(LEGACY_RSA.as_bytes(), Some("wrong")),
            Err(KeyError::WrongPassphrase)
        );
    }

    fn ppk(headers: &str) -> String {
        format!(
            "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: aes256-cbc\nComment: phone\nPublic-Lines: 0\n\
             Key-Derivation: Argon2id\n{headers}Argon2-Parallelism: 1\nArgon2-Salt: 07070707070707070707070707070707\n\
             Private-Lines: 0\nPrivate-MAC: 00\n"
        )
    }

    #[test]
    fn an_import_refuses_a_putty_key_that_asks_for_excessive_kdf_work() {
        let memory = "the key's passphrase protection asks for 4294967295 KiB of memory, more than the 131072 KiB \
                      this app works through";
        let passes = "the key's passphrase protection asks for 257 passes, more than the 256 this app works through";

        assert_eq!(refusal(&ppk("Argon2-Memory: 4294967295\nArgon2-Passes: 8\n")), memory);
        assert_eq!(refusal(&ppk("Argon2-Memory: 8192\nArgon2-Passes: 257\n")), passes);
        // a repeated header, whichever of its values the reader keeps
        assert_eq!(
            refusal(&ppk(
                "Argon2-Memory: 8192\nArgon2-Memory: 4294967295\nArgon2-Passes: 8\n"
            )),
            memory
        );
        assert_eq!(
            refusal(&ppk(
                "Argon2-Memory: 4294967295\nArgon2-Memory: 8192\nArgon2-Passes: 8\n"
            )),
            memory
        );
        assert_eq!(
            refusal(&format!(" \n{}", ppk("Argon2-Memory: 8192\nArgon2-Passes: 257\n"))),
            passes
        );
    }

    #[test]
    fn a_putty_key_within_the_caps_is_worked_through() {
        // no key under the passphrase: the derivation runs and the key does not open, which is not a refusal
        assert_eq!(
            import(ppk("Argon2-Memory: 64\nArgon2-Passes: 1\n").as_bytes(), Some("secret")),
            Err(KeyError::WrongPassphrase)
        );
    }

    /// ssh-key's `tests/examples/id_ed25519_enc.ppk` (Apache-2.0 OR MIT): a throwaway key from puttygen, its
    /// passphrase `123`.
    const PUTTY_ED25519: &str = include_str!("../tests/fixtures/putty-ed25519-aes256.ppk");

    #[test]
    fn an_encrypted_putty_key_imports_with_its_passphrase() {
        let imported = import(PUTTY_ED25519.as_bytes(), Some("123")).unwrap();

        assert!(imported.authorized_key.starts_with("ssh-ed25519 "));
        assert_eq!(
            import(PUTTY_ED25519.as_bytes(), None),
            Err(KeyError::PassphraseRequired)
        );
        assert_eq!(
            import(PUTTY_ED25519.as_bytes(), Some("")),
            Err(KeyError::PassphraseRequired)
        );
        assert_eq!(
            import(PUTTY_ED25519.as_bytes(), Some("wrong")),
            Err(KeyError::WrongPassphrase)
        );
    }

    #[test]
    fn a_putty_key_that_is_not_encrypted_never_asks_for_a_passphrase() {
        let plain = PUTTY_ED25519.replacen("Encryption: aes256-cbc", "Encryption: none", 1);
        let unknown = PUTTY_ED25519.replacen("Encryption: aes256-cbc", "Encryption: rot13", 1);

        for text in [plain, unknown] {
            for passphrase in [None, Some("123")] {
                assert!(
                    matches!(import(text.as_bytes(), passphrase), Err(KeyError::Invalid { .. })),
                    "{text}"
                );
            }
        }
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

        let first = export(&pair.private_key, locked("correct horse")).unwrap();
        let second = export(&pair.private_key, locked("correct horse")).unwrap();

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
    fn an_export_refuses_what_is_not_a_stored_key() {
        let pair = generate("phone").unwrap();

        assert!(matches!(
            export(b"hello", locked("correct horse")),
            Err(KeyError::Invalid { .. })
        ));
        let exported = export(&pair.private_key, locked("correct horse")).unwrap();
        assert_eq!(
            export(exported.as_bytes(), locked("another one")),
            Err(KeyError::PassphraseRequired)
        );
    }

    #[test]
    fn an_export_refuses_a_passphrase_under_eight_characters_as_a_person_counts_them() {
        let pair = generate("phone").unwrap();
        let short = Err(KeyError::PassphraseTooShort { minimum: 8 });
        // seven family emoji: 7 characters to a person, 49 code points, 175 bytes
        let families = "👨‍👩‍👧‍👦".repeat(7);

        assert_eq!(export(&pair.private_key, locked("")), short);
        assert_eq!(export(&pair.private_key, locked("1234567")), short);
        assert_eq!(export(&pair.private_key, locked(&families)), short);
        assert_eq!(export(&pair.private_key, locked("e\u{301}".repeat(7).as_str())), short);
        // seven Devanagari conjuncts: 7 characters by Unicode 15.1's rule, 14 by the older one
        assert_eq!(export(&pair.private_key, locked("क्ष".repeat(7).as_str())), short);
        assert_eq!(
            short.clone().unwrap_err().to_string(),
            "the passphrase needs at least 8 characters"
        );

        for enough in ["12345678", "пароль12", &format!("{families}👨‍👩‍👧‍👦")] {
            assert!(!export_passphrase_too_short(enough));
            let exported = export(&pair.private_key, locked(enough)).unwrap();
            assert_eq!(
                import(exported.as_bytes(), Some(enough)).unwrap().fingerprint,
                pair.fingerprint
            );
        }
    }

    #[test]
    fn the_too_short_check_is_the_exports_own() {
        let pair = generate("phone").unwrap();

        for passphrase in [
            "",
            "1234567",
            "12345678",
            "क्ष".repeat(7).as_str(),
            "क्ष".repeat(8).as_str(),
        ] {
            assert_eq!(
                export_passphrase_too_short(passphrase),
                export(&pair.private_key, locked(passphrase)).is_err(),
                "{passphrase}"
            );
        }
    }

    #[test]
    fn an_import_takes_a_key_under_any_passphrase_however_short() {
        let pair = generate("laptop").unwrap();
        let key = load(&pair.private_key).unwrap();

        let imported = import(&encrypted(&key, "x"), Some("x")).unwrap();

        assert_eq!(imported.fingerprint, pair.fingerprint);
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
