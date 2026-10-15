//
//  ProxyTunnel.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import Network

/// 在浏览器连接与上游连接之间双向透传字节, 普通请求、事件流和 WebSocket 都适用.
/// 任意一端结束时, 把已收到的数据发完再关闭两端
final class ProxyTunnel {
    private let client: NWConnection
    private let upstream: NWConnection
    private let initialData: Data
    private let queue: DispatchQueue
    private var onFailure: (() -> Void)?
    private var opened = false
    private var closed = false

    /// - Parameters:
    ///   - initialData: 上游连上后首先发送的数据, 即改写后的请求头和已读到的请求体
    ///   - onFailure: 上游未连上时回调, 由调用方给浏览器响应错误
    init(client: NWConnection, upstream: NWConnection, initialData: Data, queue: DispatchQueue, onFailure: @escaping () -> Void) {
        self.client = client
        self.upstream = upstream
        self.initialData = initialData
        self.queue = queue
        self.onFailure = onFailure
    }

    /// 上游尚未启动时调用, 由隧道负责连接
    func start() {
        upstream.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                run()
            case .waiting, .failed:
                // 端口未监听时进入 waiting 而不是 failed, 两者都视为连接失败
                if opened {
                    close()
                } else {
                    fail()
                }
            case .cancelled:
                close()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// 上游已就绪(如经 usbmuxd 建立的连接)时调用
    func run() {
        guard !opened, !closed else { return }
        opened = true
        onFailure = nil
        let closeOnEnd: (NWConnection.State) -> Void = { [self] state in
            switch state {
            case .failed, .cancelled:
                close()
            default:
                break
            }
        }
        client.stateUpdateHandler = closeOnEnd
        upstream.stateUpdateHandler = closeOnEnd
        upstream.send(content: initialData, completion: .contentProcessed { [self] error in
            if error != nil {
                close()
            }
        })
        pump(from: client, to: upstream)
        pump(from: upstream, to: client)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, isComplete, error in
            if closed {
                return
            }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [self] error in
                    if error != nil {
                        close()
                    }
                })
            }
            if isComplete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
                    close()
                })
                return
            }
            pump(from: source, to: destination)
        }
    }

    private func fail() {
        guard !closed else { return }
        closed = true
        upstream.stateUpdateHandler = nil
        upstream.cancel()
        let handler = onFailure
        onFailure = nil
        handler?()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        client.stateUpdateHandler = nil
        upstream.stateUpdateHandler = nil
        client.cancel()
        upstream.cancel()
    }
}
