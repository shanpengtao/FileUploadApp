//
//  QRCodeGenerator.swift
//  FileUploadApp
//
//  使用 CoreImage 生成二维码 NSImage
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

func generateQRCode(from string: String, size: CGFloat = 160) -> NSImage {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "H"

    guard let outputImage = filter.outputImage else {
        return NSImage(size: NSSize(width: size, height: size))
    }

    // 缩放到目标尺寸
    let scaleX = size / outputImage.extent.size.width
    let scaleY = size / outputImage.extent.size.height
    let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
        return NSImage(size: NSSize(width: size, height: size))
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
}
