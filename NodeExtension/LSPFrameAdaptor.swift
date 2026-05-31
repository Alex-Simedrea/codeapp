//
//  LSPFrameAdaptor.swift
//  extension
//
//  Created by Ken Chung on 14/08/2024.
//

import Foundation

class LSPFrameAdaptor {
    var onSendToWebSocket: ((String) -> Void)?
    var onWriteToStdin: ((String) -> Void)?
    private var buffer = Data()
    private let headerSeparator = Data("\r\n\r\n".utf8)
    private let contentLengthMarker = Data("Content-Length:".utf8)

    func receiveWebSocket(data: String){
        let message = "Content-Length: \(String(data.utf8.count))\r\n\r\n\(data)"
        onWriteToStdin?(message)
    }

    private func contentLength(from header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "content-length"
            {
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }

    private func dropPrefixBeforeNextHeader() -> Bool {
        guard let markerRange = buffer.range(of: contentLengthMarker) else {
            let keepCount = min(buffer.count, contentLengthMarker.count - 1)
            if keepCount > 0 {
                let suffixStart = buffer.index(buffer.endIndex, offsetBy: -keepCount)
                buffer = Data(buffer[suffixStart..<buffer.endIndex])
            } else {
                buffer.removeAll(keepingCapacity: true)
            }
            return false
        }
        if markerRange.lowerBound > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<markerRange.lowerBound)
        }
        return true
    }

    func receiveStdout(data: Data){
        buffer.append(data)

        while true {
            guard dropPrefixBeforeNextHeader() else { return }
            guard let headerRange = buffer.range(of: headerSeparator) else { return }

            let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8),
                  let length = contentLength(from: header)
            else {
                buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                continue
            }

            let bodyStart = headerRange.upperBound
            let bodyEnd = bodyStart + length
            guard buffer.count >= bodyEnd else { return }

            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            if let message = String(data: body, encoding: .utf8) {
                onSendToWebSocket?(message)
            }
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
    }
}
