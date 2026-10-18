import Foundation

extension PilotViewModel {
    var calibrationActive: Bool {
        calibrationFlow.phase == .active && (calibrationFlow.expiresAt ?? .distantPast) > Date()
    }
    /// Explicit, calibration-only permission. No AI, screenshot, or running command.
    func beginPointerCalibration() async {
        guard !isSessionActive, !taskFlow.isBusy, !probing, !calibrationRequestInFlight else {
            notice = "请先取消当前计划或停止任务，再开始独立的指针校准。"; return
        }
        guard storageWarning == nil else { notice = storageWarning!; return }
        do {
            _ = try AddressPolicy.device(configuration.deviceURL)
            if !deviceToken.isEmpty { try SecretStore.save(deviceToken, account: configuration.deviceAccount); deviceToken = "" }
            _ = try SecretStore.load(configuration.deviceAccount)
        } catch { notice = error.localizedDescription; return }
        let snapshot = configuration
        calibrationConfiguration = snapshot
        calibrationFlow = PointerCalibrationState(phase: .starting, stopGeneration: SharedStore.shared.stopGeneration, deviceURL: snapshot.deviceURL)
        let id = calibrationFlow.id
        calibrationRequestInFlight = true
        defer { calibrationRequestInFlight = false }
        let client = HardwareClient(configuration: snapshot)
        var sentArm = false
        do {
            var device = try await client.status()
            guard calibrationIsCurrent(id, phase: .starting) else { return }
            guard device.hid_connected, !device.busy else { throw PilotError.message("请先完成 BLE 配对，并确保设备没有在途动作。") }
            if device.supportsSoftwareControl {
                guard !device.armed else { throw PilotError.message("设备已被授权，请先停止旧控制再开始短时校准。") }
                guard device.control_lease_mode != nil, device.lease_remaining_ms != nil else {
                    throw PilotError.message("请先更新固件以支持60秒专用校准授权；不会使用普通任务授权代替。")
                }
                sentArm = true
                device = try await client.armSoftwareControl(expected: device, mode: "calibration")
                guard calibrationIsCurrent(id, phase: .starting) else { try await client.stopAndVerify(); return }
            }
            guard device.armed, device.control_lease_mode == "calibration",
                  let remaining = device.lease_remaining_ms, remaining > 0, remaining <= 60_000 else {
                throw PilotError.message("当前固件未提供60秒专用校准模式，请升级；普通任务的旧硬件模式仍兼容。")
            }
            calibrationFlow.bootID = device.boot_id
            calibrationFlow.sessionID = device.session_id
            calibrationFlow.controlEpoch = device.control_epoch
            calibrationFlow.expiresAt = Date().addingTimeInterval(Double(min(60_000, device.lease_remaining_ms ?? 60_000)) / 1000)
            calibrationFlow.phase = .active
            notice = "仅允许60秒内的指针微移；不截图、不调用AI、不点击或输入。观察后请结束校准。"
            calibrationTimeoutTask?.cancel()
            calibrationTimeoutTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self, self.calibrationFlow.id == id else { return }
                self.calibrationTimeoutTask = nil
                await self.endPointerCalibration()
            }
        } catch {
            var stopped = true
            if sentArm { do { try await client.stopAndVerify() } catch { stopped = false } }
            guard calibrationFlow.id == id, calibrationFlow.phase != .stopping else { return }
            calibrationFlow.phase = .error
            calibrationFlow.errorMessage = stopped ? error.localizedDescription : "校准授权结果不明且未确认停止，请拔掉 USB 电源。"
            notice = calibrationFlow.errorMessage!
        }
    }
    private func calibrationIsCurrent(_ id: UUID, phase: PointerCalibrationState.Phase) -> Bool {
        calibrationFlow.id == id && calibrationFlow.phase == phase &&
        calibrationFlow.stopGeneration == SharedStore.shared.stopGeneration &&
        calibrationFlow.deviceURL == configuration.deviceURL
    }
    func endPointerCalibration() async {
        if calibrationFlow.phase == .stopping {
            while calibrationFlow.phase == .stopping {
                // Another shutdown owns the network requests; wait for its verified outcome.
                if Task.isCancelled { await Task.yield() }
                else { try? await Task.sleep(nanoseconds: 50_000_000) }
            }
            return
        }
        guard calibrationFlow.isBusy || calibrationFlow.phase == .error, calibrationFlow.phase != .stopping,
              let snapshot = calibrationConfiguration else { return }
        calibrationFlow.phase = .stopping
        calibrationTimeoutTask?.cancel(); calibrationTimeoutTask = nil
        let client = HardwareClient(configuration: snapshot)
        // Revoke immediately, then drain older ARM/move requests and verify again.
        try? await client.stopAndVerify()
        while calibrationRequestInFlight || sending {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { break }
        }
        var stopped = false
        if !calibrationRequestInFlight && !sending {
            do { try await client.stopAndVerify(); stopped = true } catch {}
        }
        calibrationFlow.finish(stopped: stopped)
        notice = calibrationFlow.errorMessage ?? "设备已确认停止。只有你实际观察到正确移动后，才确认校准。"
    }
    @discardableResult
    func confirmPointerCalibration() -> Bool {
        guard calibrationFlow.phase == .finished, calibrationFlow.moved,
              calibrationFlow.deviceURL == configuration.deviceURL, !isSessionActive else {
            notice = "请先完成微移、结束并确认设备停止，再人工确认观察结果。"; return false
        }
        var saved = SharedStore.shared.configuration
        saved.deviceURL = configuration.deviceURL
        saved.calibrationX = configuration.calibrationX; saved.calibrationY = configuration.calibrationY
        saved.orientation = configuration.orientation
        saved.relativeModeConfirmed = true; saved.calibratedAt = Date()
        do {
            try saved.validate()
            try SharedStore.shared.write(saved, to: "configuration.json")
            configuration.relativeModeConfirmed = true; configuration.calibratedAt = saved.calibratedAt
            calibrationFlow = PointerCalibrationState()
            notice = "已保存你确认的校准结果。控制已停止；新任务仍需计划和单独授权。"
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    func moveCalibrationPointer(dx: Int, dy: Int) async {
        guard !sending, calibrationFlow.allowsMove(dx: dx, dy: dy),
              let snapshot = calibrationConfiguration else { notice = "仅在短时校准授权内允许单轴微移。"; return }
        let id = calibrationFlow.id
        sending = true
        defer { sending = false }
        do {
            let client = HardwareClient(configuration: snapshot)
            let device = try await client.status()
            guard calibrationIsCurrent(id, phase: .active), calibrationFlow.allowsMove(dx: dx, dy: dy),
                  device.boot_id == calibrationFlow.bootID, device.session_id == calibrationFlow.sessionID,
                  device.control_epoch == calibrationFlow.controlEpoch else { throw CancellationError() }
            let action = ActionProposal(type: .move, dx: dx, dy: dy, purpose: "navigation", risk: "low",
                requiresConfirmation: false, reason: "用户明确选择的校准微移", pointerVisible: true, highRisk: false, confidence: 1)
            try await client.send(action, expectedSession: calibrationFlow.sessionID,
                frameDeadline: calibrationFlow.expiresAt,
                stillAuthorized: { self.calibrationIsCurrent(id, phase: .active) && self.calibrationFlow.allowsMove(dx: dx, dy: dy) },
                sessionAuthorized: { self.calibrationIsCurrent(id, phase: .active) && self.calibrationFlow.allowsMove(dx: dx, dy: dy) })
            guard calibrationIsCurrent(id, phase: .active) else { return }
            calibrationFlow.moved = true
            notice = "硬件已完成微移。请亲自观察方向和距离；完成后结束校准。"
        } catch {
            // Clear sending before draining, to avoid waiting on this same move.
            sending = false
            notice = "微移中止：\(error.localizedDescription)"
            await endPointerCalibration()
        }
    }
}
