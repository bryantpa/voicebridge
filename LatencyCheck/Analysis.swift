import Foundation

enum DelayAnalysis {
    // Inputs are RMS envelopes on the same host-clock grid, 2 ms per bin.
    static func smooth(_ input: [Double]) -> [Double] {
        var result=input
        for i in 5..<(input.count-5) { result[i]=input[(i-5)...(i+5)].reduce(0,+)/11 }
        return result
    }
    static func correlate(_ x:[Double],_ y:[Double],_ validX:[Bool],_ validY:[Bool],_ range:Range<Int>,_ lag:Int)->Double {
        var sx=0.0,sy=0.0,sxx=0.0,syy=0.0,sxy=0.0,n=0.0
        for i in range {
            let j=i+lag
            guard j>=0,j<y.count,validX[i],validY[j] else {continue}
            let a=x[i],b=y[j];sx+=a;sy+=b;sxx+=a*a;syy+=b*b;sxy+=a*b;n+=1
        }
        guard n>Double(range.count)*0.95 else{return -1}
        let vx=sxx-sx*sx/n,vy=syy-sy*sy/n
        guard vx>1e-12,vy>1e-12 else{return -1}
        return (sxy-sx*sy/n)/sqrt(vx*vy)
    }
    static func estimate(_ raw:[Double],_ processed:[Double],_ rawValid:[Bool],_ processedValid:[Bool])->[String:Any] {
        let x=smooth(raw),y=smooth(processed)
        let range=500..<4000
        let scores=(-100...500).map{($0,correlate(x,y,rawValid,processedValid,range,$0))}
        let best=scores.max{$0.1<$1.1}!
        let competitor=scores.filter{abs($0.0-best.0)>20}.map{$0.1}.max() ?? -1
        let windows=[500..<1600,1600..<2700,2700..<3800]
        let estimates=windows.map { r -> (Int,Double) in
            (-100...500).map{($0,correlate(x,y,rawValid,processedValid,r,$0))}.max{$0.1<$1.1}!
        }
        let strong=estimates.filter{$0.1>0.6}
        let spread=strong.count>=2 ? (strong.map{$0.0}.max()!-strong.map{$0.0}.min()!)*2 : -1
        let rawPeak=raw.max() ?? 0,processedPeak=processed.max() ?? 0
        let valid=best.1>0.65 && best.1-competitor>0.025 && spread>=0 && spread<=30 && best.0>=0 && best.0<500 && rawPeak>0.001 && processedPeak>0.0001
        return ["accepted":valid,"delayMS":best.0*2,"correlation":best.1,"competingPeakCorrelation":competitor,"windowSpreadMS":spread,"windowEstimates":estimates.map{["delayMS":Double($0.0*2),"correlation":$0.1]},"rawPeakEnvelopeDBFS":20*log10(max(rawPeak,1e-12)),"processedPeakEnvelopeDBFS":20*log10(max(processedPeak,1e-12)),"gridResolutionMS":2,"scope":"Local RODE input-device timeline to UNIFY Chat input-device timeline; excludes call-app, network and remote playback latency. Device timestamp accuracy is not independently calibrated."]
    }
    static func selftest() -> Bool {
        var seed:UInt64=7
        func random()->Double {seed=seed &* 6364136223846793005 &+ 1;return Double(seed>>32)/Double(UInt32.max)}
        let n=5000,lag=117
        var raw=[Double](repeating:0,count:n),out=raw
        for i in stride(from:0,to:n,by:37) {let value=random()*0.04;for j in i..<min(i+37,n){raw[j]=value}}
        for i in lag..<n {out[i]=raw[i-lag]*0.6+random()*0.0001}
        let valid=[Bool](repeating:true,count:n)
        let result=estimate(raw,out,valid,valid)
        let silence=estimate(Array(repeating:0,count:n),Array(repeating:0,count:n),valid,valid)
        let badCoverage=estimate(raw,out,Array(repeating:false,count:n),valid)
        let zero=estimate(raw,raw,valid,valid)
        return result["accepted"] as? Bool == true && result["delayMS"] as? Int == 234 && silence["accepted"] as? Bool == false && badCoverage["accepted"] as? Bool == false && zero["delayMS"] as? Int == 0
    }
}
