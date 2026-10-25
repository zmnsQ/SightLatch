
@main struct AccessoryConnectionTests {
    @MainActor static func main() async {
        precondition(pairingErrorSummary(nil) == "none")
        precondition(pairingErrorSummary(NSError(domain: "CBErrorDomain", code: 7)) == "CBErrorDomain:7")
        precondition(pairingErrorSummary(NSError(domain: "private-canary", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "private-payload"])) == "other:5")
        let identifier = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        var time = start
        var connected = 0
        var failures = 0
        var transport: SightLatchSelectedAccessoryConnection? = .init(identifier: identifier,
            deadline: start.addingTimeInterval(30), now: { time }) { event in
                switch event { case .connected: connected += 1; case .failed: failures += 1 }
            }
        let central = CBCentralManager.latest!
        let peripheral = CBPeripheral(identifier: identifier)
        central.available = [peripheral]
        precondition(central.connections.isEmpty)
        central.state = .poweredOn
        transport!.centralManagerDidUpdateState(central)
        transport!.centralManagerDidUpdateState(central)
        precondition(central.retrieved == [[identifier]] && central.connections == [identifier])
        precondition(!transport!.retainAfterVerification())
        let unrelated = CBPeripheral(identifier: UUID())
        transport!.centralManager(central, didConnect: unrelated)
        precondition(connected == 0)
        peripheral.state = .connected
        transport!.centralManager(central, didConnect: peripheral)
        precondition(connected == 1 && failures == 0)
        precondition(transport!.retainAfterVerification())
        weak var retained = transport
        transport = nil // Dismissing the sheet must not drop the verified transport.
        precondition(retained != nil && central.cancellations.isEmpty)
        peripheral.state = .disconnected
        retained!.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
        precondition(retained == nil && central.connections.count == 1)

        // Explicit system-mouse recovery releases verified app transports without
        // another connect or accepting a delayed callback from the old owner.
        var systemTransport: SightLatchSelectedAccessoryConnection? = .init(identifier: identifier,
            deadline: start.addingTimeInterval(30), now: { time }) { _ in }
        let systemCentral = CBCentralManager.latest!
        let systemPeripheral = CBPeripheral(identifier: identifier)
        systemCentral.available = [systemPeripheral]; systemCentral.state = .poweredOn
        systemTransport!.centralManagerDidUpdateState(systemCentral)
        systemPeripheral.state = .connected
        precondition(systemTransport!.retainAfterVerification())
        weak var released = systemTransport
        systemTransport = nil
        SightLatchSelectedAccessoryConnection.releaseRetainedConnections()
        precondition(released == nil && systemCentral.cancellations == [identifier])
        precondition(systemCentral.connections == [identifier] && systemCentral.delegate == nil)

        // Deadline expiry while Bluetooth powers on cannot start a late connection.
        let expired = SightLatchSelectedAccessoryConnection(identifier: identifier,
            deadline: start.addingTimeInterval(30), now: { time }) { event in
                if case .failed = event { failures += 1 }
            }
        let expiredCentral = CBCentralManager.latest!
        expiredCentral.available = [CBPeripheral(identifier: identifier)]
        time = start.addingTimeInterval(31)
        expiredCentral.state = .poweredOn
        expired.centralManagerDidUpdateState(expiredCentral)
        precondition(expiredCentral.connections.isEmpty && failures == 1)

        // Cancellation fences delayed state/connection callbacks and drops the request.
        time = start
        let cancelled = SightLatchSelectedAccessoryConnection(identifier: identifier,
            deadline: start.addingTimeInterval(30), now: { time }) { _ in preconditionFailure("Late callback escaped cancellation") }
        let cancelledCentral = CBCentralManager.latest!
        let pending = CBPeripheral(identifier: identifier)
        cancelledCentral.available = [pending]
        cancelledCentral.state = .poweredOn
        cancelled.centralManagerDidUpdateState(cancelledCentral)
        cancelled.cancel()
        cancelled.centralManagerDidUpdateState(cancelledCentral)
        cancelled.centralManager(cancelledCentral, didConnect: pending)
        precondition(cancelledCentral.connections == [identifier] && cancelledCentral.cancellations == [identifier])

        // Retrieval must not silently substitute another peripheral.
        let mismatch = SightLatchSelectedAccessoryConnection(identifier: identifier,
            deadline: start.addingTimeInterval(30), now: { time }) { event in
                if case .failed = event { failures += 1 }
            }
        let mismatchCentral = CBCentralManager.latest!
        mismatchCentral.available = [unrelated]
        mismatchCentral.state = .poweredOn
        mismatch.centralManagerDidUpdateState(mismatchCentral)
        precondition(mismatchCentral.connections.isEmpty && failures == 2)

        // A late successful connection cannot outlive its original pairing deadline.
        let late = SightLatchSelectedAccessoryConnection(identifier: identifier,
            deadline: start.addingTimeInterval(30), now: { time }) { event in
                switch event { case .connected: preconditionFailure("Expired connection accepted"); case .failed: failures += 1 }
            }
        let lateCentral = CBCentralManager.latest!
        let latePeripheral = CBPeripheral(identifier: identifier)
        lateCentral.available = [latePeripheral]
        lateCentral.state = .poweredOn
        late.centralManagerDidUpdateState(lateCentral)
        time = start.addingTimeInterval(31)
        latePeripheral.state = .connected
        late.centralManager(lateCentral, didConnect: latePeripheral)
        precondition(lateCentral.cancellations == [identifier] && failures == 3)

        // ASK can report availability asynchronously. A startup 4→5 transition
        // must be observed before treating the manager as unavailable.
        var transientFailed = false
        let transient = SightLatchSelectedAccessoryConnection(identifier: identifier,
            deadline: Date().addingTimeInterval(1)) { event in
                if case .failed = event { transientFailed = true }
            }
        let transientCentral = CBCentralManager.latest!
        transientCentral.available = [CBPeripheral(identifier: identifier)]
        transientCentral.state = .poweredOff
        transient.centralManagerDidUpdateState(transientCentral)
        precondition(transientCentral.connections.isEmpty && !transientFailed)
        transientCentral.state = .poweredOn
        transient.centralManagerDidUpdateState(transientCentral)
        precondition(transientCentral.connections == [identifier] && !transientFailed)

        // Persistent 4 fails within the ORIGINAL short deadline, not a fresh 2 s.
        var unavailable = false
        let poweredOff = SightLatchSelectedAccessoryConnection(identifier: identifier,
            deadline: Date().addingTimeInterval(0.025)) { event in
                if case .failed = event { unavailable = true }
            }
        let poweredOffCentral = CBCentralManager.latest!
        poweredOffCentral.state = .poweredOff
        poweredOff.centralManagerDidUpdateState(poweredOffCentral)

        // Cancellation during the grace interval cannot report a late failure.
        var cancelledGraceCallback = false
        let cancelledGrace = SightLatchSelectedAccessoryConnection(identifier: identifier,
            deadline: Date().addingTimeInterval(0.025)) { _ in cancelledGraceCallback = true }
        let cancelledGraceCentral = CBCentralManager.latest!
        cancelledGraceCentral.state = .poweredOff
        cancelledGrace.centralManagerDidUpdateState(cancelledGraceCentral)
        cancelledGrace.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(unavailable && poweredOffCentral.connections.isEmpty)
        precondition(!cancelledGraceCallback && !transientFailed)
        transient.cancel()
        // Only the exact CoreBluetooth stale-pairing error offers that repair.
        for domain in [CBErrorDomain, "unrelated-domain"] {
            var message = ""
            let stale = SightLatchSelectedAccessoryConnection(identifier: identifier,
                deadline: Date().addingTimeInterval(1)) { event in
                    if case .failed(let reason) = event { message = reason }
                }
            let staleCentral = CBCentralManager.latest!
            let stalePeripheral = CBPeripheral(identifier: identifier)
            staleCentral.available = [stalePeripheral]
            staleCentral.state = .poweredOn
            stale.centralManagerDidUpdateState(staleCentral)
            stale.centralManager(staleCentral, didFailToConnect: stalePeripheral,
                error: NSError(domain: domain, code: 14))
            precondition(message.contains("配对信息已失效") == (domain == CBErrorDomain))
        }
        print("PASS: selected-only transport, bounded deadline, cancellation, identity rejection, verified retention, and no reconnect")
        print("PASS: startup poweredOff→poweredOn grace, persistent unavailability deadline, and grace cancellation")
    }
}
