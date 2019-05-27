import Foundation
import HSCryptoKit

class Peer {
    enum PeerError: Error {
        case peerBestBlockIsLessThanOne
        case peerHasExpiredBlockChain(localHeight: Int32, peerHeight: Int32)
        case peerNotFullNode
        case peerDoesNotSupportBloomFilter
    }

    private var remotePeerValidated: Bool = false
    private var versionSent: Bool = false
    private var mempoolSent: Bool = false

    weak var delegate: PeerDelegate?

    private let connection: IPeerConnection
    private let connectionTimeoutManager: IConnectionTimeoutManager
    private var tasks: [PeerTask] = []

    private let queue: DispatchQueue
    private let network: INetwork

    private let logger: Logger?

    var announcedLastBlockHeight: Int32 = 0
    var localBestBlockHeight: Int32 = 0
    // TODO seems like property connected is not needed. It is always true in PeerManager. Need to check it and remove
    var connected: Bool = false

    var protocolVersion: Int32 {
        return network.protocolVersion
    }

    var ready: Bool {
        return connected && tasks.isEmpty
    }

    var host: String {
        return connection.host
    }

    var logName: String {
        return connection.logName
    }

    init(host: String, network: INetwork, connection: IPeerConnection, connectionTimeoutManager: IConnectionTimeoutManager, queue: DispatchQueue? = nil, logger: Logger? = nil) {
        self.connection = connection
        self.connectionTimeoutManager = connectionTimeoutManager
        self.network = network
        self.logger = logger

        if let queue = queue {
            self.queue = queue
        } else {
            self.queue = DispatchQueue(label: "Peer: \(host)", qos: .userInitiated)
        }

        connection.delegate = self
    }

    deinit {
        connection.disconnect(error: nil)
    }

    private func sendVersion() {
        let versionMessage = VersionMessage(
                version: protocolVersion,
                services: 0x00,
                timestamp: Int64(Date().timeIntervalSince1970),
                yourAddress: NetworkAddress(services: 0x00, address: connection.host, port: UInt16(connection.port)),
                myAddress: NetworkAddress(services: 0x00, address: "::ffff:127.0.0.1", port: UInt16(connection.port)),
                nonce: 0,
                userAgent: "/WalletKit:0.1.0/",
                startHeight: localBestBlockHeight,
                relay: false
        )

        connection.send(message: versionMessage)
    }

    private func sendVerack() {
        connection.send(message: VerackMessage())
    }

    private func handle(message: IMessage) throws {
        if let versionMessage = message as? VersionMessage {
            handle(message: versionMessage)
            return
        } else if let _ = message as? VerackMessage {
            handleVerackMessage()
            return
        }

        guard self.connected else {
            return
        }

        switch message {
        case let pingMessage as PingMessage: handle(message: pingMessage)
        case _ as PongMessage: ()
        default: try handle(anyMessage: message)
        }
    }

    private func handle(message: VersionMessage) {
        do {
            try validatePeerVersion(message: message)
            remotePeerValidated = true
        } catch {
            disconnect(error: error)
            return
        }

        self.announcedLastBlockHeight = message.startHeight ?? 0

        sendVerack()
        connected = true
        delegate?.peerDidConnect(self)
    }

    private func validatePeerVersion(message: VersionMessage) throws {
        guard let startHeight = message.startHeight, startHeight > 0 else {
            throw PeerError.peerBestBlockIsLessThanOne
        }

        guard startHeight >= localBestBlockHeight else {
            throw PeerError.peerHasExpiredBlockChain(localHeight: localBestBlockHeight, peerHeight: startHeight)
        }

        guard message.hasBlockChain(network: network) else {
            throw PeerError.peerNotFullNode
        }

        guard message.supportsBloomFilter(network: network) else {
            throw PeerError.peerDoesNotSupportBloomFilter
        }
    }

    private func handleVerackMessage() {
        guard remotePeerValidated && !connected else {
            return
        }

        connected = true
        delegate?.peerDidConnect(self)
    }

    private func handle(message: PingMessage) {
        let pongMessage = PongMessage(nonce: message.nonce)
        connection.send(message: pongMessage)
    }

    private func handle(anyMessage: IMessage) throws {
        for task in tasks {
            if try task.handle(message: anyMessage) {
                return
            }
        }

        delegate?.peer(self, didReceiveMessage: anyMessage)
    }

    private func log(_ message: String, level: Logger.Level = .debug, file: String = #file, function: String = #function, line: Int = #line) {
        logger?.log(level: level, message: message, file: file, function: function, line: line, context: logName)
    }

}

extension Peer: IPeer {

    func connect() {
        connection.connect()
    }

    func disconnect(error: Error? = nil) {
        self.connection.disconnect(error: error)
    }

    func add(task: PeerTask) {
        tasks.append(task)
        if tasks.count == 1 {
            delegate?.peerBusy(self)
        }

        task.delegate = self
        task.requester = self

        task.start()
    }

    func filterLoad(bloomFilter: BloomFilter) {
        let filterLoadMessage = FilterLoadMessage(bloomFilter: bloomFilter)

        connection.send(message: filterLoadMessage)
    }

    func sendMempoolMessage() {
        if !mempoolSent {
            connection.send(message: MemPoolMessage())
            mempoolSent = true
        }
    }

    func sendPing(nonce: UInt64) {
        let message = PingMessage(nonce: nonce)

        connection.send(message: message)
    }

    func equalTo(_ other: IPeer?) -> Bool {
        return self.host == other?.host
    }

}

extension Peer: PeerConnectionDelegate {

    func connectionAlive() {
        connectionTimeoutManager.reset()
    }

    func connectionTimePeriodPassed() {
        connectionTimeoutManager.timePeriodPassed(peer: self)

        queue.async { [weak self] in
            if let task = self?.tasks.first {
                task.checkTimeout()
            }
        }
    }

    func connectionReadyForWrite() {
        if !versionSent {
            sendVersion()
            versionSent = true
        }
    }

    func connectionDidDisconnect(withError error: Error?) {
        connected = false
        delegate?.peerDidDisconnect(self, withError: error)
    }

    func connection(didReceiveMessage message: IMessage) {
        queue.async { [weak self] in
            do {
                try self?.handle(message: message)
            } catch {
                self?.log("Message handling failed with error: \(error)", level: .warning)
                self?.disconnect(error: error)
            }
        }
    }

}

extension Peer: IPeerTaskDelegate {

    func handle(completedTask task: PeerTask) {
        log("Handling completed task: \(type(of: task))")
        if let index = tasks.index(where: { $0 === task }) {
            let task = tasks.remove(at: index)
            delegate?.peer(self, didCompleteTask: task)
        }

        if let task = tasks.first {
            // Reset timer for the next task in list
            task.resetTimer()
        }

        if tasks.isEmpty {
            delegate?.peerReady(self)
        }
    }

    func handle(failedTask task: PeerTask, error: Error) {
        log("Handling failed task: \(type(of: task))")
        disconnect(error: error)
    }

}

extension Peer: IPeerTaskRequester {

    func send(message: IMessage) {
        connection.send(message: message)
    }

}
