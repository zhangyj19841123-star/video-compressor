#if VC_CLI
import Foundation

// 独立命令行自测入口：不启动 GUI，直接验证引擎 / 画质 / 恒定帧率
// 用法：VC_FFMPEG=/path/to/ffmpeg vc-selftest /path/to/video.mp4
@main
struct SelfTestCLI {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            print("usage: vc-selftest <video-file>")
            exit(2)
        }
        SelfTest.run(path: CommandLine.arguments[1])
    }
}
#endif
