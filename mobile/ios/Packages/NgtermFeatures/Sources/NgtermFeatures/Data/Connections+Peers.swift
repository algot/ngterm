import NgtermCore

// The apps the machines and their sessions run, as the listings name them: a machine may run ngterm and agterm both.
extension Connections {
    // a listing names each session's app; the machine's is another app than ngterm only when every session's is (a
    // machine may run both). An empty listing says nothing, so the app learned before stays
    internal func learnPeer(_ machineId: String, _ sessions: [RemoteSession]) {
        var apps: [PeerKind: MachinePeer] = [:]
        var foreign: [SessionKey: MachinePeer] = [:]
        for session in sessions {
            guard let kind = session.peer, kind != .ngterm else {
                continue
            }
            let app = apps[kind] ?? MachinePeer(kind: kind)
            apps[kind] = app
            foreign[SessionKey(machineId: machineId, sessionId: session.id)] = app
        }
        let known = sessionPeers.filter { $0.key.machineId != machineId }.merging(foreign) { _, new in new }
        if known != sessionPeers {
            sessionPeers = known
        }
        let kind: PeerKind? =
            if sessions.isEmpty {
                nil
            } else if foreign.count == sessions.count {
                sessions.first?.peer
            } else {
                sessions.lazy.compactMap(\.peer).first { $0 == .ngterm }
            }
        guard let kind, peers[machineId]?.kind != kind else {
            return
        }
        peers[machineId] = apps[kind] ?? MachinePeer(kind: kind)
    }

    // a machine's connection is gone, and with it what its listings said of its apps
    internal func forgetPeers(_ machineId: String) {
        peers[machineId] = nil
        if sessionPeers.keys.contains(where: { $0.machineId == machineId }) {
            sessionPeers = sessionPeers.filter { $0.key.machineId != machineId }
        }
    }
}
