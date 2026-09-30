//
// Glass.swift
// GlassVPN
// 液态玻璃适配: macOS 26+ 使用 glassEffect / 玻璃按钮, 更早系统回退为毛玻璃材质。
// `#if compiler(>=6.2)` 保证用旧版 Xcode (无 macOS 26 SDK) 也能编译。
//

import SwiftUI

extension View {

    func glassCard(cornerRadius: CGFloat = 16, padding: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, padding: padding, tint: tint))
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            legacyButton(prominent)
        }
        #else
        legacyButton(prominent)
        #endif
    }

    /// 圆形可交互玻璃, 用于连接按钮; 按下时有液态形变反馈
    @ViewBuilder
    func glassCircle(tint: Color?) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: Circle())
        } else {
            legacyCircle(tint)
        }
        #else
        legacyCircle(tint)
        #endif
    }

    @ViewBuilder
    fileprivate func legacyButton(_ prominent: Bool) -> some View {
        if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    fileprivate func legacyCircle(_ tint: Color?) -> some View {
        self
            .background(Circle().fill(tint ?? Color.clear))
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.12)))
    }
}

private struct GlassCard: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let tint: Color?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.padding(padding).glassEffect(.regular.tint(tint), in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: shape)
            .background(shape.fill(tint ?? Color.clear))
            .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
    }
}

/// 多块玻璃放进同一个容器, macOS 26 上相邻玻璃共享采样并有融合动画
struct GlassStack<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                VStack(spacing: spacing) { content }
            }
        } else {
            VStack(spacing: spacing) { content }
        }
        #else
        VStack(spacing: spacing) { content }
        #endif
    }
}
