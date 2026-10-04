// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors

import Foundation
import AppKit

/// Observation evidence, deliberately separate from dispatch and intent assertions.
enum ScrollEvidence {
    static func region(_ value:Any?, bounds:Any?) -> [Double]? {
        guard let r=AutomationModel.coordinateBounds(value),let b=AutomationModel.coordinateBounds(bounds),
              r[0]>=0,r[1]>=0,r[0]+r[2]<=b[2],r[1]+r[3]<=b[3] else {return nil}
        return r
    }

    static func geometry(before:[[String:Any]],after:[[String:Any]],region:[Double]?,root:String?,direction:String) -> [String:Any] {
        // Unscoped window changes cannot establish target-area motion.
        guard region != nil || root != nil else {return ["status":"unverified","reason":"No reliable target-area scope"]}
        var old:[String:[String:Any]]=[:]
        for n in before {if let id=n["id"] as? String {old[id]=n}}
        var moved:[[String:Any]]=[]
        for n in after {
            guard let id=n["id"] as? String,let p=old[id],
                  let a=AutomationModel.coordinateBounds(p["frame"]),let b=AutomationModel.coordinateBounds(n["frame"]),
                  abs(a[2]-b[2])<1,abs(a[3]-b[3])<1 else {continue}
            if let root, !(p["ancestors"] as? [String] ?? []).contains(root) {continue}
            if let r=region {
                let box=CGRect(x:r[0],y:r[1],width:r[2],height:r[3])
                guard box.intersects(CGRect(x:a[0],y:a[1],width:a[2],height:a[3])) || box.intersects(CGRect(x:b[0],y:b[1],width:b[2],height:b[3])) else {continue}
            }
            if n["role"] as? String == "AXScrollBar",p["valueLimited"] as? Bool != true,n["valueLimited"] as? Bool != true,
               let from=Double(String(describing:p["value"] ?? "")),let to=Double(String(describing:n["value"] ?? "")),from.isFinite,to.isFinite,
               (a[3]>a[2]) == ["up","down"].contains(direction),
               (to-from)*(["down","right"].contains(direction) ? 1.0 : -1.0)>0.000001 {
                return ["status":"movement_observed","basis":"scoped AX scrollbar value in requested direction","samples":[["id":id,"before":from,"after":to]],"count":1,"causality":"Observed after input; concurrent user/app changes are possible"]
            }
            let dx=b[0]-a[0],dy=b[1]-a[1]
            let primary=["up","down"].contains(direction) ? dy:dx
            let cross=["up","down"].contains(direction) ? dx:dy
            let sign=["down","right"].contains(direction) ? -1.0:1.0
            if primary*sign>2 && abs(cross)<2 {moved.append(["id":id,"dx":dx,"dy":dy])}
        }
        // Two independently identified descendants with coherent displacement are stronger
        // evidence than a moving container, focus indicator or unrelated label change.
        let coherent=moved.filter { n in
            moved.contains { m in
                m["id"] as? String != n["id"] as? String && abs((m["dx"] as! Double)-(n["dx"] as! Double))<2 && abs((m["dy"] as! Double)-(n["dy"] as! Double))<2
            }
        }
        return ["status":coherent.count>=2 ? "movement_observed":"unverified","basis":"scoped AX displacement in requested direction","samples":Array(coherent.prefix(4)),"count":coherent.count,"causality":"Observed after input; concurrent user/app changes are possible"]
    }

    static func pixels(before:[String:Any],after:[String:Any],region:[Double]?,bounds:Any?) throws -> [String:Any] {
        func load(_ artifact:[String:Any]) throws -> CGImage {
            guard let file=artifact["file"] as? String,let image=NSImage(contentsOfFile:file),let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else {throw AutomationModel.fail("Scroll evidence image cannot be decoded")}
            return cg
        }
        let a=try load(before),b=try load(after)
        guard a.width==b.width,a.height==b.height else {throw AutomationModel.fail("Scroll evidence image dimensions changed")}
        func sample(_ source:CGImage) throws -> [UInt8] {
            var image=source
            if let r=region,let bounds=AutomationModel.coordinateBounds(bounds) {
                let sx=Double(source.width)/bounds[2],sy=Double(source.height)/bounds[3]
                guard let crop=source.cropping(to:CGRect(x:r[0]*sx,y:r[1]*sy,width:r[2]*sx,height:r[3]*sy)) else {throw AutomationModel.fail("Scroll evidence crop unavailable")}
                image=crop
            }
            var bytes=[UInt8](repeating:0,count:128*128)
            let ok=bytes.withUnsafeMutableBytes { ptr -> Bool in
                guard let ctx=CGContext(data:ptr.baseAddress,width:128,height:128,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else {return false}
                ctx.draw(image,in:CGRect(x:0,y:0,width:128,height:128));return true
            }
            guard ok else {throw AutomationModel.fail("Scroll evidence image sampler unavailable")};return bytes
        }
        let x=try sample(a),y=try sample(b)
        let count=zip(x,y).filter{abs(Int($0.0)-Int($0.1))>12}.count
        return ["status":count>32 ? "visual_change_observed":"no_visual_change_observed","changedFraction":Double(count)/Double(x.count),"scope":region == nil ? "whole_window":"region","sampling":"128x128 grayscale; difference >12, more than32 pixels","meaning":"Visual difference is not proof of scroll displacement or boundary; cursor/animation may contribute"]
    }
}
