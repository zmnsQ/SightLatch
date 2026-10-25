import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SecretStore { static func load(_ account: String) throws -> String { "test-only" } }
final class Transport {
    static let shared = Transport()
    var calls: [URLRequest] = []
    var handler: ((URLRequest) async throws -> Data)!
    func send(_ request: URLRequest) async throws -> Data {
        calls.append(request); return try await handler(request)
    }
}
actor ChatGPTPlanClient {
    static let shared = ChatGPTPlanClient()
    var instructions = ""
    func response(model: String, instructions: String, task: String, jpeg: Data) async throws -> String {
        self.instructions = instructions + task
        return #"{"type":"wait","purpose":"navigation","risk":"low","requiresConfirmation":false,"reason":"等待新画面","pointerVisible":false,"highRisk":false,"confidence":1}"#
    }
}
@main struct AbsolutePointerTests {
    static let epoch = String(repeating: "e", count: 32)
    static let boot = String(repeating: "b", count: 32)
    static func fixture() throws -> (PilotConfiguration, DeviceStatus, AbsolutePointerContext) {
        var config = PilotConfiguration()
        config.deviceURL = "http://10.0.0.2"; config.allowLowRiskNavigation = true
        let calibration = PointerCalibrationContext(deviceURL: config.deviceURL, phoneModel: "fixture",
            orientation: "portrait", pixelWidth: 1260, pixelHeight: 2736, scale: 3)
        let mapping = AbsolutePointerMapping(hardwareBootID: boot, hidGeneration: 7,
            screenFromHID: .init(a: 0.126, b: 0, c: 0, d: 0, e: 0.2736, f: 0),
            maxResidualPixels: 1.5, verifiedAt: Date(), validationPointCount: 2,
            validatedHIDBounds: .init(minX: 500, maxX: 9500, minY: 500, maxY: 9500))
        config.automaticCalibrationProfile = .init(context: calibration, pixelsPer100X: 504,
            pixelsPer100Y: 1094.4, verifiedAt: Date(), hardwareBootID: boot, absoluteMapping: mapping)
        let device = try status()
        let geometry = CaptureGeometry(sourceWidth: 884, sourceHeight: 1920, orientedWidth: 884,
            orientedHeight: 1920, jpegWidth: 590, jpegHeight: 1280)
        return (config, device, try device.absolutePointerContext(configuration: config, geometry: geometry, frameID: "frame")!)
    }
    static func status(generation: Int = 7, action: String? = nil, known: Bool = false) throws -> DeviceStatus {
        var object: [String: Any] = ["ok":true,"boot_id":boot,"uptime_ms":100,"armed":true,
            "hid_connected":true,"session_id":"session","next_sequence":2,"busy":false,
            "control_epoch":epoch,"control_lease_mode":"calibration","hid_generation":generation,
            "absolute_pointer_supported":true,"absolute_probe_supported":true,"absolute_position_known":known]
        if let action {
            object["last_action_id"]=action;object["last_action_state"]="completed"
            object["absolute_hid_x"]=5000;object["absolute_hid_y"]=5000
        }
        return try JSONDecoder().decode(DeviceStatus.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func encoded(_ device: DeviceStatus, action: String? = nil) throws -> Data {
        var object: [String: Any] = ["ok":device.ok,"boot_id":device.boot_id,"uptime_ms":device.uptime_ms,
            "armed":device.armed,"hid_connected":device.hid_connected,"session_id":device.session_id,
            "next_sequence":device.next_sequence,"busy":false,"control_epoch":device.control_epoch!,
            "control_lease_mode":"calibration","hid_generation":device.hid_generation!,
            "absolute_pointer_supported":true,"absolute_probe_supported":true,"absolute_position_known":action != nil]
        if let action { object["last_action_id"]=action;object["last_action_state"]="completed";object["absolute_hid_x"]=5000;object["absolute_hid_y"]=5000 }
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func proposal(_ kind: ActionProposal.Kind = .click) -> ActionProposal {
        .init(type: kind, button: kind == .click ? "left" : nil, purpose: "navigation", risk: "low",
            requiresConfirmation: false, reason: "查看当前界面", pointerVisible: false, highRisk: false,
            confidence: 0.99, absoluteTarget: .init(frameID: "frame", x: 295, y: 640, left: 275, top: 620, right: 315, bottom: 660))
    }
    static func main() async throws {
        let (config, device, context) = try fixture()
        let point = try context.logicalTarget(proposal().absoluteTarget!)
        precondition(point.x == 5000 && point.y == 5000)
        precondition(!device.absolute_position_known! && device.hasVerifiedPointerCalibration(configuration: config))
        precondition(SafetyGate.rejection(proposal(), task: "导航", config: config, frameID: "frame", capturedAt: Date(), absoluteContext: context) == nil)
        precondition(SafetyGate.rejection(proposal(), task: "导航", config: config, frameID: "frame") != nil)
        for mutation in 0..<8 {
            var action = proposal()
            switch mutation {
            case 0: action.dx = 1
            case 1: action.absoluteTarget!.frameID = "old"
            case 2: action.absoluteTarget!.x = .nan
            case 3: action.absoluteTarget!.left = -1
            case 4: action.absoluteTarget!.right = 295.1
            case 5: action.absoluteTarget!.x = 10;action.absoluteTarget!.left=0;action.absoluteTarget!.right=20
            case 6: action.confidence = 0.84
            default: action.type = .scroll; action.wheel = 1;action.absoluteTarget=nil
            }
            precondition(SafetyGate.rejection(action, task: "导航", config: config, frameID: "frame", capturedAt: Date(), absoluteContext: context) != nil)
        }
        var legacy = config; legacy.automaticCalibrationProfile=nil;legacy.relativeModeConfirmed=true
        precondition(!device.hasVerifiedPointerCalibration(configuration: legacy))
        var invalid = config; invalid.invalidatePointerCalibration()
        precondition(!invalid.hasVerifiedPointerCalibration && invalid.automaticCalibrationProfile == nil)
        var oldDevice=device, oldConfig=config
        oldDevice.absolute_pointer_supported=nil;oldDevice.boot_id="different-boot"
        oldConfig.automaticCalibrationProfile!.absoluteMapping=nil;oldConfig.relativeModeConfirmed=true
        precondition(!oldDevice.hasVerifiedPointerCalibration(configuration:oldConfig))
        oldDevice.boot_id=boot;precondition(oldDevice.hasVerifiedPointerCalibration(configuration:oldConfig))
        try messageChecks(config, context)
        launchChecks(config, context)
        try await wireChecks(config, device, context)
        var modelConfig=config;modelConfig.provider="chatgpt-plan";modelConfig.model="fixture";modelConfig.uploadConsent=true;modelConfig.chatGPTPlanConsent=true
        _ = try await AIClient(configuration: modelConfig).propose(jpeg: Data(), task: "导航", frameID: "frame", absoluteContext: context)
        let prompt = await ChatGPTPlanClient.shared.instructions
        precondition(prompt.contains("screenshot may contain NO mouse pointer") && prompt.contains("absoluteTarget"))
        precondition(!prompt.contains("Relative mouse only") && !prompt.contains("For move/click the pointer and next target must be visually located"))
        let messageGoal="打开微信给文件传输助手发送消息：你好"
        let messageScope=MessageScope(intent:MessageIntent.parse(messageGoal)!,sessionID:"test",generation:0,expiresAt:Date().addingTimeInterval(100))
        _ = try await AIClient(configuration:modelConfig).propose(jpeg:Data(),task:messageGoal,frameID:"frame",messageScope:messageScope,absoluteContext:context)
        let scopedPrompt=await ChatGPTPlanClient.shared.instructions
        for conflicting in ["Return one relative move", "After paste, only small relative moves", "pointerVisible=true; evidence", "and sendButtonUnderPointer=true", "or the pointer/next target cannot yet be located"] {
            precondition(!scopedPrompt.contains(conflicting),"Conflicting absolute prompt: \(conflicting)")
        }
        precondition(scopedPrompt.contains("targetIsOpenButton=true") && scopedPrompt.contains("targetIsSendButton=true") && scopedPrompt.contains("JPEG pixels from each horizontal target edge"))
        print("PASS: production absolute JPEG→screen→HID mapping/bounds, cursor-free gates and exact scoped targets; fresh generation, bounded TTL, STOP fencing, one POST and no relative fallback; no real API/HID")
    }
    static func launchChecks(_ config: PilotConfiguration, _ context: AbsolutePointerContext) {
        let now=Date(), uptime=ProcessInfo.processInfo.systemUptime
        let goal="打开微信给文件传输助手发送消息：你好"
        var command=SessionCommand(task:goal,running:true,createdAt:now.addingTimeInterval(-3))
        command.messageScope = .init(intent:MessageIntent.parse(goal)!,sessionID:command.id,generation:0,expiresAt:now.addingTimeInterval(100))
        var action=proposal();action.purpose="app_launch_confirmation"
        action.launchEvidence = .init(frameID:"frame",targetApp:"微信",systemOpenConfirmation:true,
            dialogText:"在微信中打开",openButtonText:"打开",openButtonUnderPointer:false,
            targetAppVisible:false,foregroundApp:"SightLatch",targetIsOpenButton:true)
        func rejected(_ value:ActionProposal)->Bool {
            SafetyGate.rejection(value,task:goal,config:config,command:command,frameID:"frame",capturedAt:now,
                capturedUptime:uptime,absoluteContext:context) != nil
        }
        precondition(!rejected(action))
        action.launchEvidence!.targetIsOpenButton=false;action.launchEvidence!.openButtonUnderPointer=true;action.pointerVisible=true
        precondition(rejected(action),"Absolute mode borrowed legacy under-pointer evidence")
    }
    static func messageChecks(_ config: PilotConfiguration, _ context: AbsolutePointerContext) throws {
        let now=Date(), uptime=ProcessInfo.processInfo.systemUptime
        let goal="打开微信给文件传输助手发送消息：你好"
        var command=SessionCommand(task: goal, running: true, createdAt: now.addingTimeInterval(-3))
        command.messageScope = .init(intent: MessageIntent.parse(goal)!, sessionID: command.id,
            generation: 0, expiresAt: now.addingTimeInterval(100))
        command.messageScope!.launch.phase = .opened
        command.messageScope!.launch.visuallyEstablishedAt=now.addingTimeInterval(-1)
        command.messageScope!.launch.visuallyEstablishedUptime=uptime-1
        command.messageScope!.launch.visuallyEstablishedFrameID="launch"
        command.messageScope!.pasteAttempted=true
        var action=proposal();action.purpose="message_send";action.risk="authorized_message"
        action.messageEvidence = .init(frameID:"frame",app:"微信",recipient:"文件传输助手",recipientUnambiguous:true,
            composerFocused:true,composerText:"你好",sendButtonUnderPointer:false,outgoingText:"",newOutgoingMessage:false,
            deliveryState:"unknown",targetIsSendButton:true)
        func rejected(_ value: ActionProposal, _ cmd: SessionCommand) -> Bool {
            SafetyGate.rejection(value,task:goal,config:config,command:cmd,frameID:"frame",capturedAt:now,
                capturedUptime:uptime,absoluteContext:context) != nil
        }
        precondition(!rejected(action,command))
        action.messageEvidence!.targetIsSendButton=false;precondition(rejected(action,command))
        action.pointerVisible=true;action.messageEvidence!.sendButtonUnderPointer=true
        precondition(rejected(action,command),"Absolute send borrowed legacy cursor evidence")
        action.messageEvidence!.targetIsSendButton=true;command.messageScope!.sendAttempted=true
        precondition(rejected(action,command))
    }
    static func wireChecks(_ config: PilotConfiguration, _ device: DeviceStatus, _ context: AbsolutePointerContext) async throws {
        let transport=Transport.shared, hardware=HardwareClient(configuration:config)
        var accepted="", postCount=0, reserved=0
        transport.handler = { request in
            if request.url!.path == "/v1/action" {
                postCount += 1
                let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                precondition(body.count==11 && body["type"] as? String=="click_absolute")
                precondition(body["hid_x"] as? Int==5000 && body["hid_y"] as? Int==5000)
                precondition((body["ttl_ms"] as! Int) <= 1200 && (body["ttl_ms"] as! Int) >= 800)
                accepted=body["id"] as! String
                return try JSONSerialization.data(withJSONObject:["ok":true,"id":accepted])
            }
            return try encoded(device,action:accepted.isEmpty ? nil : accepted)
        }
        try await hardware.send(proposal(),expectedSession:"session",frameDeadline:Date().addingTimeInterval(1.2),
            absoluteContext:context,reserveMessageAction:{reserved += 1})
        precondition(postCount==1 && reserved==1)
        accepted="";postCount=0;reserved=0
        do {
            try await hardware.send(proposal(),expectedSession:"session",frameDeadline:Date().addingTimeInterval(0.5),
                absoluteContext:context,reserveMessageAction:{reserved += 1})
            preconditionFailure("Insufficient click TTL dispatched")
        } catch HardwareClient.PreDispatchFailure.frameExpired {}
        precondition(postCount==0 && reserved==0)
        transport.handler={ _ in try encoded(status(generation:8)) }
        do { try await hardware.send(proposal(),expectedSession:"session",absoluteContext:context);preconditionFailure("Generation mismatch dispatched") }
        catch is PilotError {}
        transport.handler={ _ in try encoded(device) }
        do { try await hardware.send(proposal(.move),expectedSession:"session");preconditionFailure("Missing mapping fell back") }
        catch is PilotError {}
        var cancelled=false
        do {
            try await hardware.send(proposal(),expectedSession:"session",absoluteContext:context,
                stillAuthorized:{!cancelled},reserveMessageAction:{cancelled=true})
            preconditionFailure("STOP during reservation dispatched")
        } catch is CancellationError {}
        postCount=0
        transport.handler={ request in
            if request.url!.path == "/v1/action" { postCount += 1; throw URLError(.timedOut) }
            return try encoded(device)
        }
        do { try await hardware.send(proposal(),expectedSession:"session",absoluteContext:context);preconditionFailure("Lost POST reply accepted") }
        catch is URLError {}
        precondition(postCount==1,"Uncertain action replayed")
        accepted="";postCount=0
        transport.handler={ request in
            if request.url!.path == "/v1/action" {
                postCount += 1
                let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                accepted=body["id"] as! String
                return try JSONSerialization.data(withJSONObject:["ok":true,"id":accepted])
            }
            return try encoded(accepted.isEmpty ? device : status(generation:8),action:accepted.isEmpty ? nil : accepted)
        }
        do { try await hardware.send(proposal(),expectedSession:"session",absoluteContext:context);preconditionFailure("Reconnected generation accepted") }
        catch is PilotError {}
        precondition(postCount==1)
        accepted="";postCount=0
        var order:[String]=[]
        transport.handler={ request in
            if request.url!.path == "/v1/action" {
                postCount += 1;order.append("post")
                let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                precondition(body.count==11 && body["type"] as? String=="probe_absolute")
                accepted=body["id"] as! String
                return try JSONSerialization.data(withJSONObject:["ok":true,"id":accepted])
            }
            return try encoded(device,action:accepted.isEmpty ? nil : accepted)
        }
        let completed=try await hardware.sendAbsoluteCalibrationProbe(id:"probe",hidX:5000,hidY:5000,
            expectedBootID:boot,expectedHIDGeneration:7,expectedSession:"session",expectedControlEpoch:epoch,
            frameDeadline:Date().addingTimeInterval(60),stillAuthorized:{true},willDispatch:{order.append("window")})
        precondition(postCount==1 && order==["window","post"] && completed.absolute_position_known==true)
    }
}
