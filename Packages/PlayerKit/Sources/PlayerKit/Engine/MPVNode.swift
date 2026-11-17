import Foundation
import Libmpv

/// A structured value from the engine (its lists of tracks, chapters and so on), copied
/// into Swift so it can cross threads and be tested without the engine.
indirect enum MPVNode: Sendable, Equatable {
    case none
    case string(String)
    case flag(Bool)
    case int(Int64)
    case double(Double)
    case array([MPVNode])
    case map([String: MPVNode])
    case bytes(Data)

    /// Copies an engine node. The caller still owns (and frees) the original.
    init(_ node: mpv_node) {
        switch node.format {
        case MPV_FORMAT_STRING:
            self = node.u.string.map { .string(String(cString: $0)) } ?? .none
        case MPV_FORMAT_FLAG:
            self = .flag(node.u.flag != 0)
        case MPV_FORMAT_INT64:
            self = .int(node.u.int64)
        case MPV_FORMAT_DOUBLE:
            self = .double(node.u.double_)
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee, let values = list.values else {
                self = .array([])
                return
            }
            self = .array((0 ..< Int(list.num)).map { MPVNode(values[$0]) })
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee, let values = list.values, let keys = list.keys else {
                self = .map([:])
                return
            }
            var map: [String: MPVNode] = [:]
            for index in 0 ..< Int(list.num) {
                if let key = keys[index] {
                    map[String(cString: key)] = MPVNode(values[index])
                }
            }
            self = .map(map)
        case MPV_FORMAT_BYTE_ARRAY:
            guard let bytes = node.u.ba?.pointee, let data = bytes.data else {
                self = .bytes(Data())
                return
            }
            self = .bytes(Data(bytes: data, count: bytes.size))
        default:
            self = .none
        }
    }

    subscript(key: String) -> MPVNode? {
        if case let .map(map) = self {
            map[key]
        } else {
            nil
        }
    }

    var elements: [MPVNode] {
        if case let .array(elements) = self {
            elements
        } else {
            []
        }
    }

    /// A non-empty string.
    var text: String? {
        if case let .string(text) = self, !text.isEmpty {
            text
        } else {
            nil
        }
    }

    var integer: Int? {
        switch self {
        case let .int(value): Int(value)
        case let .double(value): Int(exactly: value.rounded())
        default: nil
        }
    }

    var number: Double? {
        switch self {
        case let .double(value): value
        case let .int(value): Double(value)
        default: nil
        }
    }

    var isTrue: Bool {
        self == .flag(true)
    }

    var data: Data? {
        if case let .bytes(data) = self {
            data
        } else {
            nil
        }
    }
}
