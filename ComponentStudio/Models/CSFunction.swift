//
//  CSFunction.swift
//  ComponentStudio
//
//  Created by devin_abbott on 8/10/17.
//  Copyright © 2017 Devin Abbott. All rights reserved.
//

import Foundation

struct CSFunction {
    struct Invocation: CSDataSerializable, CSDataDeserializable {
        var name: String = "none"
        var arguments: NamedArguments = [:]
        
        init() {}
        
        init(_ data: CSData) {
            self.name = String(data.get(key: "name"))
            self.arguments = data.get(key: "arguments").objectValue.reduce([:], { (result, item) -> NamedArguments in
                var result = result
                result[item.key] = CSFunction.Argument(item.value)
                return result
            })
        }
        
        func run(in scope: CSScope) -> ReturnValue {
            let function = CSFunction.getFunction(named: name)
            return function.invoke(arguments, scope)
        }
        
        var canBeInvoked: Bool {
            let function = CSFunction.getFunction(named: name)
        
            for parameter in function.parameters {
                if arguments[parameter.name] == nil {
                    return false
                }
            }
            
            return true
        }
        
        func toData() -> CSData {
            return CSData.Object([
                "name": name.toData(),
                "arguments": arguments.toData(),
            ])
        }
        
        // Returns nil if no concrete type was found
        func concreteTypeForArgument(named argumentName: String, in scope: CSScope) -> CSType? {
            let function = CSFunction.getFunction(named: self.name)
            
//            Swift.print("concrete type for", argumentName)
            
            guard let matchingParameter = function.parameters.first(where: { $0.name == argumentName }) else { return nil }
            
            if !matchingParameter.variableType.isGeneric { return matchingParameter.variableType }
            
            for parameter in function.parameters {
                // If we reach this parameter, there was no concrete type
                if parameter.name == argumentName { break }
                
                if parameter.variableType.genericId == matchingParameter.variableType.genericId, let argument = arguments[parameter.name] {
                    let resolved = argument.resolve(in: scope).type
//                    Swift.print("resolved generic type", resolved)
                    return resolved
                }
            }
            
            return nil
        }
    }
    
    enum ParameterType {
        case variable(type: CSType, access: CSAccess)
        case keyword(type: CSType)
        case declaration
    }
    
    struct Parameter {
        var label: String?
        var name: String
        var type: ParameterType
        
        var variableType: CSType {
            switch self.type {
            case .variable(type: let type, access: _): return type
            case .keyword(type: let type): return type
            case .declaration: return CSType.undefined
            }
        }
        
        var access: CSAccess {
            switch self.type {
            case .variable(type: _, access: let access): return access
            case .keyword(type: _): return CSAccess.read
            case .declaration: return CSAccess.write
            }
        }
    }
    
    enum Argument: CSDataSerializable, CSDataDeserializable {
        init(_ data: CSData) {
            switch data.get(key: "type").stringValue {
            case "value":
                self = .value(CSValue(data.get(key: "value")))
            case "identifier":
                let identifierType = CSType(data.get(keyPath: ["value", "type"]))
                let identifierPath = data.get(keyPath: ["value", "path"]).arrayValue.map({ $0.stringValue })
                self = .identifier(identifierType, identifierPath)
            default:
                self = .value(CSUndefinedValue)
            }
        }
        
        func toData() -> CSData {
            switch self {
            case .value(let value):
                return CSData.Object([
                    "type": .String("value"),
                    "value": value.toData(),
                ])
            case .identifier(let type, let keyPath):
                return CSData.Object([
                    "type": .String("identifier"),
                    "value": CSData.Object([
                        "type": type.toData(),
                        "path": keyPath.toData(),
                    ])
                ])
            }
        }
        
        case value(CSValue)
        case identifier(CSType, [String])
        
        func resolve(in scope: CSScope) -> CSValue {
            switch self {
            case .value(let value): return value
            // TODO: Verify that the type matches what's in scope? Or we can just rely on the fact
            // that most uses of a variable won't work with the wrong type
            case .identifier(_, let keyPath):
                if keyPath.count == 0 { return CSUndefinedValue }
                return scope.getValueAt(keyPath: keyPath)
            }
        }
        
        var keyPath: [String]? {
            switch self {
            case .value(_): return nil
            case .identifier(_, let name): return name
            }
        }
        
        static var customValue: String { return "custom" }
        static var noneValue: String { return "none" }
        static var noneKeyPath: [String] { return [noneValue] }
        static var customKeyPath: [String] { return [customValue] }
        static var customValueKeyPath: [String] { return [customValue, "value"] }
        static var customTypeKeyPath: [String] { return [customValue, "type"] }
    }
    
    enum ControlFlow {
        case stepOver, stepInto
    }
    
    typealias NamedArguments = [String: Argument]
    
    typealias ReturnValue = (scope: CSScope, controlFlow: ControlFlow)
    
    var name: String
    var parameters: [Parameter]
    var hasBody: Bool
    
    // Named parameters are populated (pulled from scope) by the execution context
    var invoke: (NamedArguments, CSScope) -> ReturnValue = { _, scope in (scope, .stepOver) }
    
    static var registeredFunctionNames: [String] {
        return Array(registeredFunctions.keys)
    }
    
    static var registeredFunctions: [String: CSFunction] = [
        "none": CSFunction.noneFunction,
        "Append": CSAppendFunction,
        "Assign": CSAssignFunction,
        "If": CSIfFunction,
    ]
    
    static var noneFunction: CSFunction {
        return CSFunction(
            name: "none",
            parameters: [],
            hasBody: false,
            invoke: { _, scope in (scope, .stepOver) }
        )
    }
    
    static func register(function: CSFunction) {
        registeredFunctions[function.name] = function
    }
    
    static func getFunction(named name: String) -> CSFunction {
        return registeredFunctions[name] ?? notFound(name: name)
    }
    
    static func notFound(name: String) -> CSFunction {
        return CSFunction(
            name: "Function \(name) not found",
            parameters: [],
            hasBody: true,
            invoke: { _, scope in (scope, .stepOver) }
        )
    }
}

let CSAssignFunction = CSFunction(
    name: "Assign",
    parameters: [
        CSFunction.Parameter(label: nil, name: "lhs", type: .variable(type: CSGenericTypeA, access: .read)),
        CSFunction.Parameter(label: "to", name: "rhs", type: .variable(type: CSGenericTypeA, access: .write)),
    ],
    hasBody: false,
    invoke: { (arguments, scope) -> CSFunction.ReturnValue in
        let lhs = arguments["lhs"]!.resolve(in: scope)
        guard case CSFunction.Argument.identifier(_, let rhsKeyPath) = arguments["rhs"]! else { return (scope, .stepOver) }
        scope.set(keyPath: rhsKeyPath, to: lhs)
        
        return (scope, .stepOver)
    }
)

let CSIfFunction = CSFunction(
    name: "If",
    parameters: [
        CSFunction.Parameter(label: nil, name: "lhs", type: .variable(type: CSGenericTypeA, access: .read)),
        CSFunction.Parameter(label: "is", name: "cmp", type: .keyword(type: CSComparatorType)),
        CSFunction.Parameter(label: nil, name: "rhs", type: .variable(type: CSGenericTypeA, access: .read)),
    ],
    hasBody: true,
    invoke: { arguments, scope in
        let lhs = arguments["lhs"]!.resolve(in: scope)
        let cmp = arguments["cmp"]!.resolve(in: scope)
        let rhs = arguments["rhs"]!.resolve(in: scope)
        
        switch cmp.type {
        case CSComparatorType:
            switch cmp.data.stringValue {
            case "equal to":
                return (scope, lhs.data == rhs.data ? .stepInto : .stepOver)
            case "greater than":
                return (scope, lhs.data.numberValue > rhs.data.numberValue ? .stepInto : .stepOver)
            case "greater than or equal to":
                return (scope, lhs.data.numberValue >= rhs.data.numberValue ? .stepInto : .stepOver)
            case "less than":
                return (scope, lhs.data.numberValue < rhs.data.numberValue ? .stepInto : .stepOver)
            case "less than or equal to":
                return (scope, lhs.data.numberValue <= rhs.data.numberValue ? .stepInto : .stepOver)
            default:
                break
            }
        default:
            break
        }
        
        return (scope, .stepOver)
    }
)

let CSAppendFunctionInvocation: (CSFunction.NamedArguments, CSScope) -> CSFunction.ReturnValue = { arguments, scope in
    let componentValue = arguments["component"]!.resolve(in: scope)
    let baseValue = arguments["base"]!.resolve(in: scope)
    guard case CSFunction.Argument.identifier(_, let baseKeyPath) = arguments["base"]! else { return (scope, .stepOver) }
    
    let result = CSValue(type: CSURLType, data: CSData.String(baseValue.data.stringValue + componentValue.data.stringValue))
    scope.set(keyPath: baseKeyPath, to: result)
    
    return (scope, .stepOver)
}

let CSAppendFunction = CSFunction(
    name: "Append",
    parameters: [
        CSFunction.Parameter(
            label: "the component",
            name: "component",
            type: CSFunction.ParameterType.variable(type: CSType.string, access: .read)
        ),
        CSFunction.Parameter(
            label: "to",
            name: "base",
            type: CSFunction.ParameterType.variable(type: CSURLType, access: .write)
        ),
    ],
    hasBody: false,
    invoke: CSAppendFunctionInvocation
)