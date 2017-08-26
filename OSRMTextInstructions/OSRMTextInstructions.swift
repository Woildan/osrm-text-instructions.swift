import Foundation
import MapboxDirections

extension String {
    public var sentenceCased: String {
        return String(characters.prefix(1)).uppercased() + String(characters.dropFirst())
    }
}

public class OSRMInstructionFormatter: Formatter {
    let version: String
    public var locale: Locale? {
        didSet {
            updateTable()
        }
    }
    var table: [String: Any]!
    var instructions: [String: Any] {
        return table[version] as! [String: Any]
    }
    
    let ordinalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = .current
        if #available(iOS 9.0, OSX 10.11, *) {
            formatter.numberStyle = .ordinal
        }
        return formatter
    }()
    
    public init(version: String) {
        self.version = version
        
        super.init()
        
        updateTable()
    }
    
    required public init?(coder decoder: NSCoder) {
        if let version = decoder.decodeObject(of: NSString.self, forKey: "version") as String? {
            self.version = version
        } else {
            return nil
        }
        
        super.init(coder: decoder)
        
        updateTable()
    }
    
    override public func encode(with coder: NSCoder) {
        super.encode(with: coder)
        
        coder.encode(version, forKey: "version")
    }
    
    func updateTable() {
        let bundle = Bundle(for: OSRMInstructionFormatter.self)
        var path: String?
        if let locale = locale, let localeIdentifier = Bundle.preferredLocalizations(from: bundle.preferredLocalizations, forPreferences: [locale.identifier, bundle.developmentLocalization ?? "en"]).first {
            path = bundle.path(forResource: "Instructions", ofType: "plist", inDirectory: nil, forLocalization: localeIdentifier)
        }
        if path == nil {
            path = bundle.path(forResource: "Instructions", ofType: "plist")
        }
        table = NSDictionary(contentsOfFile: path!)! as! [String: Any]
    }

    var constants: [String: Any] {
        return instructions["constants"] as! [String: Any]
    }
    
    func laneConfig(intersection: Intersection) -> String? {
        guard let approachLanes = intersection.approachLanes else {
            return ""
        }

        guard let useableApproachLanes = intersection.usableApproachLanes else {
            return ""
        }

        // find lane configuration
        var config = Array(repeating: "x", count: approachLanes.count)
        for index in useableApproachLanes {
            config[index] = "o"
        }

        // reduce lane configurations to common cases
        var current = ""
        return config.reduce("", {
            (result: String?, lane: String) -> String? in
            if (lane != current) {
                current = lane
                return result! + lane
            } else {
                return result
            }
        })
    }

    func directionFromDegree(degree: Int?) -> String {
        guard let degree = degree else {
            // step had no bearing_after degree, ignoring
            return ""
        }

        // fetch locatized compass directions strings
        let directions = constants["direction"] as! [String: String]

        // Transform degrees to their translated compass direction
        switch degree {
        case 340...360, 0...20:
            return directions["north"]!
        case 20..<70:
            return directions["northeast"]!
        case 70...110:
            return directions["east"]!
        case 110..<160:
            return directions["southeast"]!
        case 160...200:
            return directions["south"]!
        case 200..<250:
            return directions["southwest"]!
        case 250...290:
            return directions["west"]!
        case 290..<340:
            return directions["northwest"]!
        default:
            return "";
        }
    }
    
    typealias InstructionsByToken = [String: String]
    typealias InstructionsByModifier = [String: InstructionsByToken]
    
    override public func string(for obj: Any?) -> String? {
        return string(for: obj, legIndex: nil, numberOfLegs: nil, roadClasses: nil, modifyValueByKey: nil)
    }
    
    /**
     Creates an instruction given a step and options.
     
     - parameter step: 
     - parameter legIndex: Current leg index the user is currently on.
     - parameter numberOfLegs: Total number of `RouteLeg` for the given `Route`.
     - parameter roadClasses: Option set representing the classes of road for the `RouteStep`.
     - parameter modifyValueByKey: Allows for mutating the instruction at given parts of the instruction.
     - returns: An instruction as a `String`.
     */
    public func string(for obj: Any?, legIndex: Int?, numberOfLegs: Int?, roadClasses: RoadClasses? = RoadClasses([]), modifyValueByKey: ((TokenType, String) -> String)?) -> String? {
        guard let step = obj as? RouteStep else {
            return nil
        }
        
        var type = step.maneuverType ?? .turn
        let modifier = step.maneuverDirection?.description
        let mode = step.transportType

        if type != .depart && type != .arrive && modifier == nil {
            return nil
        }

        if instructions[type.description] == nil {
            // OSRM specification assumes turn types can be added without
            // major version changes. Unknown types are to be treated as
            // type `turn` by clients
            type = .turn
        }

        var instructionObject: InstructionsByToken
        var rotaryName = ""
        var wayName: String
        switch type {
        case .takeRotary, .takeRoundabout:
            // Special instruction types have an intermediate level keyed to “default”.
            let instructionsByModifier = instructions[type.description] as! [String: InstructionsByModifier]
            let defaultInstructions = instructionsByModifier["default"]!
            
            wayName = step.exitNames?.first ?? ""
            if let _rotaryName = step.names?.first, let _ = step.exitIndex, let obj = defaultInstructions["name_exit"] {
                instructionObject = obj
                rotaryName = _rotaryName
            } else if let _rotaryName = step.names?.first, let obj = defaultInstructions["name"] {
                instructionObject = obj
                rotaryName = _rotaryName
            } else if let _ = step.exitIndex, let obj = defaultInstructions["exit"] {
                instructionObject = obj
            } else {
                instructionObject = defaultInstructions["default"]!
            }
        default:
            var typeInstructions = instructions[type.description] as! InstructionsByModifier
            let modesInstructions = instructions["modes"] as? InstructionsByModifier
            if let mode = mode, let modesInstructions = modesInstructions, let modesInstruction = modesInstructions[mode.description] {
                instructionObject = modesInstruction
            } else if let modifier = modifier, let typeInstruction = typeInstructions[modifier] {
                instructionObject = typeInstruction
            } else {
                instructionObject = typeInstructions["default"]!
            }
            
            // Set wayName
            let name = step.names?.first
            let ref = step.codes?.first
            let isMotorway = roadClasses?.contains(.motorway) ?? false
            
            if let name = name, let ref = ref, name != ref, !isMotorway {
                wayName = modifyValueByKey != nil ? "\(modifyValueByKey!(.wayName, name)) (\(modifyValueByKey!(.code, ref)))" : "\(name) (\(ref))"
            } else if let ref = ref, isMotorway, let decimalRange = ref.rangeOfCharacter(from: .decimalDigits), !decimalRange.isEmpty {
                wayName = modifyValueByKey != nil ? "\(modifyValueByKey!(.code, ref))" : ref
            } else if name == nil, let ref = ref {
                wayName = modifyValueByKey != nil ? "\(modifyValueByKey!(.code, ref))" : ref
            } else {
                wayName = name != nil ? modifyValueByKey != nil ? "\(modifyValueByKey!(.wayName, name!))" : name! : ""
            }
        }

        // Special case handling
        var laneInstruction: String?
        switch type {
        case .useLane:
            var laneConfig: String?
            if let intersection = step.intersections?.first {
                laneConfig = self.laneConfig(intersection: intersection)
            }
            let laneInstructions = constants["lanes"] as! [String: String]
            laneInstruction = laneInstructions[laneConfig ?? ""]

            if laneInstruction == nil {
                // Lane configuration is not found, default to continue
                let useLaneConfiguration = instructions["use lane"] as! InstructionsByModifier
                instructionObject = useLaneConfiguration["no_lanes"]!
            }
        default:
            break
        }

        // Decide which instruction string to use
        // Destination takes precedence over name
        var instruction: String
        if let _ = step.destinations ?? step.destinationCodes, let _ = step.exitCodes?.first, let obj = instructionObject["exit_destination"] {
            instruction = obj
        } else if let _ = step.destinations ?? step.destinationCodes, let obj = instructionObject["destination"] {
            instruction = obj
        } else if let _ = step.exitCodes?.first, let obj = instructionObject["exit"] {
            instruction = obj
        } else if !wayName.isEmpty, let obj = instructionObject["name"] {
            instruction = obj
        } else {
            instruction = instructionObject["default"]!
        }

        // Prepare token replacements
        var nthWaypoint: String? = nil
        if let legIndex = legIndex, let numberOfLegs = numberOfLegs, legIndex != numberOfLegs - 1 {
            nthWaypoint = ordinalFormatter.string(from: (legIndex + 1) as NSNumber)
        }
        let exitCode = step.exitCodes?.first ?? ""
        let destination = [step.destinationCodes, step.destinations].flatMap { $0?.first }.joined(separator: ": ")
        var exitOrdinal: String = ""
        if let exitIndex = step.exitIndex, exitIndex <= 10 {
            exitOrdinal = ordinalFormatter.string(from: exitIndex as NSNumber)!
        }
        let modifierConstants = constants["modifier"] as! [String: String]
        let modifierConstant = modifierConstants[modifier ?? "straight"]!
        var bearing: Int? = nil
        if step.finalHeading != nil { bearing = Int(step.finalHeading! as Double) }

        // Replace tokens
        let scanner = Scanner(string: instruction)
        scanner.charactersToBeSkipped = nil
        var result = ""
        while !scanner.isAtEnd {
            var buffer: NSString?

            if scanner.scanUpTo("{", into: &buffer) {
                result += buffer! as String
            }
            guard scanner.scanString("{", into: nil) else {
                continue
            }

            var token: NSString?
            guard scanner.scanUpTo("}", into: &token) else {
                continue
            }
            
            if scanner.scanString("}", into: nil) {
                if let tokenType = TokenType(description: token! as String) {
                    var replacement: String
                    switch tokenType {
                    case .code: replacement = step.codes?.first ?? ""
                    case .wayName: replacement = wayName
                    case .destination: replacement = destination
                    case .exitCode: replacement = exitCode
                    case .exitIndex: replacement = exitOrdinal
                    case .rotaryName: replacement = rotaryName
                    case .laneInstruction: replacement = laneInstruction ?? ""
                    case .modifier: replacement = modifierConstant
                    case .direction: replacement = directionFromDegree(degree: bearing)
                    case .wayPoint: replacement = nthWaypoint ?? ""
                    }
                    if tokenType == .wayName {
                        result += replacement // already modified above
                    } else {
                        result += modifyValueByKey?(tokenType, replacement) ?? replacement
                    }
                }
            } else {
                result += token! as String
            }
            
        }

        // remove excess spaces
        result = result.replacingOccurrences(of: "\\s\\s", with: " ", options: .regularExpression)

        // capitalize
        let meta = table["meta"] as! [String: Any]
        if meta["capitalizeFirstLetter"] as? Bool ?? false {
            result = result.sentenceCased
        }
        
        return result
    }
    
    override public func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        return false
    }
}
