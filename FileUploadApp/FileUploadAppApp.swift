//
//  FileUploadAppApp.swift
//  FileUploadApp
//
//  Created by wayne on 2026/6/15.
//

import SwiftUI
import AppKit

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 在 SwiftUI Scene 初始化前先建好菜单，防止被覆盖
        buildChineseMenuBar()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildChineseMenuBar()
    }

    private func buildChineseMenuBar() {
        let mainMenu = NSMenu()

        // ── 1. 应用菜单（文件传输助手）
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(title: "关于 文件传输助手", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 文件传输助手",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "显示全部",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 文件传输助手",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // ── 2. 编辑菜单
        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // ── 3. 窗口菜单
        let windowMenuItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        windowMenu.addItem(withTitle: "最小化",
                           action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放",
                           action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(title: "进入全屏幕",
                                        action: #selector(NSWindow.toggleFullScreen(_:)),
                                        keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(fullScreenItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "将所有窗口移至前台",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        // 最后一步统一赋值，避免中途触发 KVO
        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "文件传输助手"
        alert.informativeText = """
            版本：1.0.0 (Build 1)

            作者：单鹏涛
            邮箱：shanpengtao@58.com

            一款局域网文件快传工具，
            手机扫码即可上传文件到电脑。
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.icon = NSApp.applicationIconImage
        alert.runModal()
    }
}

// MARK: - App

@main
struct FileUploadAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 620)
        .windowStyle(.titleBar)
    }
}
