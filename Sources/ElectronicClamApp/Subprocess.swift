import Foundation

/// 외부 명령 stdout 캡처 유틸 — Process+Pipe 복붙 5곳 통합 (TODO P2).
///
/// 읽기 순서: `readDataToEndOfFile()` 후 `waitUntilExit()`.
/// 이 순서는 출력이 파이프 버퍼를 초과할 경우의 데드락을 방지한다.
/// stderr는 /dev/null 상당 파이프로 버린다.
/// 실행 실패(launch 불가) 시 nil 반환. terminationStatus는 검사하지 않는다
/// (lsof 등 일부 명령은 pid 소멸 시 비정상 종료하지만 부분 출력이 유효함).
enum Subprocess {
    /// `launchPath`를 `arguments`로 실행하고 stdout 전체를 UTF-8 문자열로 반환한다.
    /// 실행 불가(바이너리 없음·권한 오류 등)이면 nil.
    static func capture(_ launchPath: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// 타임아웃 변형 — `log show` 류 시간/메모리 폭주 가능 명령용. 초과 시
    /// 자식을 SIGKILL 로 회수한다 (2026-06-11 시스템 포화 사고 재발 방지:
    /// 스왑 포화 상태에서 log show 가 메모리를 폭식 → posix_spawn 전면 실패).
    /// 자식이 또 자식을 낳는 명령에는 부족(그룹 회수 불가 — Process API 한계)
    /// 하므로 단일 프로세스 명령에만 쓸 것.
    static func capture(_ launchPath: String,
                        _ arguments: [String],
                        timeoutSeconds: Double) -> String? {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let killer = DispatchWorkItem {
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + timeoutSeconds, execute: killer)
        // SIGKILL 시 파이프가 EOF 되므로 read 는 반드시 풀린다.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()
        return String(data: data, encoding: .utf8)
    }
}
