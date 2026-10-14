# MacPulse: tài liệu cho người phát triển

Icon trên thanh menu cho MacBook Pro M4 Pro. Bấm vào icon sẽ mở bảng có 5 tab:

- Tổng quan: % CPU (từng nhân E/P), % GPU, RAM, nhiệt độ CPU/GPU/SSD/pin, công suất máy, tốc độ 2 quạt.
- Tiến trình: mọi tiến trình đang chạy, xếp theo CPU hoặc RAM, có ô tìm, gộp theo ứng dụng. Chuột phải vào một dòng để thoát, buộc thoát, hoặc ghim sang tab Tác vụ.
- Tác vụ: phiên Claude Code đang làm gì (tiêu đề phiên, model, app chứa phiên, công cụ đang chạy), việc dựng video kèm % và giờ xong dự kiến, mục "Vừa xong".
- Quạt: Tự động (macOS), Thông minh (tăng quạt khi chip vượt ngưỡng), Thủ công (thanh kéo 0 đến 100%).
- Hẹn giờ: giữ máy thức, tự ngủ hoặc tắt máy theo giờ hẹn hoặc khi xong việc.

Thanh kéo tính theo khoảng quạt của máy: 0% là 2.317 vòng/phút (mức thấp nhất), 100% là 7.826 vòng/phút.

## Tab Tác vụ lấy số liệu ở đâu

- Phiên Claude Code: đọc nhật ký `~/.claude/projects/<thư mục>/<mã phiên>.jsonl` từ cuối file (file có thể nặng hàng trăm MB). Tiến trình `claude` có cờ `--resume=<mã phiên>` thì nối chính xác; không có thì nối theo thư mục làm việc. Có danh sách việc (TodoWrite) thì tính % theo số việc xong.
- ffmpeg: % = vị trí đang đọc file nguồn (libproc) so với mốc cắt cuối cùng trong lệnh (`trim`, `-ss`, `-t`, `-to`), thời lượng video lấy bằng AVFoundation. Giờ xong tính theo tốc độ đọc trong 90 giây gần nhất.
- ffmpeg, Python, Remotion… nằm dưới phiên Claude nào là nhờ dò ngược chuỗi tiến trình cha.
- CapCut, Final Cut, Premiere, DaVinci… không lộ % ra ngoài, chỉ hiện "đang xuất" khi ngốn trên 40% CPU.

## Hẹn giờ

- Giữ máy thức dùng IOPMAssertion (`pmset -g assertions` sẽ thấy "MacPulse keep-awake"). App tắt là khóa tự nhả.
- Khi xong việc: hết tác vụ ở tab Tác vụ và không ai đụng chuột/bàn phím trong N phút (mặc định 10) thì tắt.
- Trước khi tắt luôn có bảng đếm ngược 60 giây.
- Ngủ: `pmset sleepnow`. Tắt máy: nhờ System Events tắt như menu Apple (cần cho phép trong Quyền riêng tư › Tự động hóa); nếu có app chặn quá 3 phút thì helper cho máy ngủ.
- Thử mà không tắt thật: chạy `MACPULSE_DRYRUN=1 ~/Applications/MacPulse.app/Contents/MacOS/MacPulse`.

## Build và chạy

```
./build.sh             # dựng .build/MacPulse.app
./build.sh --install   # dựng, cài vào ~/Applications rồi mở
```

Chỉ cần Command Line Tools (không cần Xcode). App và helper đều là arm64, đích macOS 14.

## Phát hành bản mới

1. Sửa code, chạy thử bằng `./build.sh --install`.
2. Thêm mục `## <phiên bản>` vào `CHANGELOG.md`, commit.
3. Chạy `./release.sh <phiên bản>`, ví dụ `./release.sh 1.1.0`.

Script tự tăng số phiên bản, dựng app, nén `.zip`, ký Ed25519, tạo `.dmg`, tính SHA-256, gắn tag và tạo bản phát hành trên GitHub. App của người dùng hỏi GitHub mỗi ngày một lần; thấy bản mới thì hiện dải "Có bản mới", bấm Cập nhật là tự tải, kiểm chữ ký, thay app và mở lại.

Cần chuẩn bị một lần:

- GitHub CLI: `~/.local/bin/gh auth login` (chọn GitHub.com, SSH, đăng nhập bằng trình duyệt).
- Khóa ký cập nhật ở `~/.config/macpulse/update_ed25519.key`, tạo bằng `swift tools/update-key.swift generate`. Khóa công khai tương ứng nằm trong `Info.plist` (khóa `MPUpdatePublicKey`). **Sao lưu file khóa này** (ví dụ vào trình quản lý mật khẩu). Mất khóa thì người dùng cũ không tự cập nhật được nữa, phải tải .dmg mới bằng tay.

Có chứng chỉ Apple Developer (99 USD/năm) thì người dùng không còn gặp cảnh báo "chưa được công chứng":

```
xcrun notarytool store-credentials macpulse   # một lần, nhập Apple ID và mật khẩu ứng dụng
DEVELOPER_ID="Developer ID Application: Tên (TEAMID)" NOTARY_PROFILE=macpulse ./release.sh 1.1.0
```

## Helper tự cập nhật ("Luôn cho phép")

Lần cài helper đầu tiên luôn hỏi mật khẩu. Nếu người dùng giữ ô "Luôn cho phép", script cài tạo file `/Library/Application Support/MacPulse/helper-auto-update` thuộc root. Về sau khi app có helper mới:

1. App ghi đường dẫn thư mục Resources của mình vào `helper-update-request`.
2. Helper (root) đọc file `MacPulseFanHelper` và `MacPulseFanHelper.sig` vào bộ nhớ, kiểm chữ ký Ed25519 bằng khóa công khai gắn cứng trong helper.
3. Khớp thì ghi đúng các byte vừa kiểm vào `/Library/PrivilegedHelperTools/`, rồi thoát để launchd chạy bản mới. Không khớp thì bỏ qua và ghi log.

Không có sudo mở rộng, không lưu mật khẩu. Chương trình khác trên máy không lợi dụng được vì chỉ bản có chữ ký bằng khóa bí mật của bạn mới được cài. `build.sh` tự ký helper nếu máy có khóa.

## Kiểm thử

- Chụp giao diện mà không đụng màn hình đang dùng: `.build/MacPulse.app/Contents/MacOS/MacPulse --qa-window "Quạt" [dark]` vẽ bảng vào cửa sổ nằm sau mọi cửa sổ, rồi chụp bằng `screencapture -l <id cửa sổ>`.
- Hẹn giờ không tắt máy thật: biến môi trường `MACPULSE_DRYRUN=1`.
- Các hàm thuần đã có phép thử nhỏ: so sánh phiên bản và kiểm chữ ký (`Updater`), giờ tắt của chế độ "Khi xong việc" (`PowerManager.autoOffAt`), gộp pipeline giải mã/mã hóa (`TaskTracker.mergePipelines`).

## Tương thích các dòng máy

App dò mọi thứ lúc chạy nên không gắn cứng theo một đời chip:

- Cảm biến nhiệt: quét toàn bộ khóa SMC có tiền tố `Tp`/`Te` (CPU) và `Tg` (GPU), bỏ khóa đọc ra số vô lý. Đời chip nào đặt tên khác vẫn bắt được.
- Quạt: số quạt đọc từ `FNum`; khoảng tốc độ đọc từ `F<i>Mn`/`F<i>Mx` của từng máy. Máy không có quạt (MacBook Air) ẩn phần điều khiển.
- M3 trở đi cần mở khóa `Ftst` trước khi ghi `F<i>Md`; M1/M2 không có khóa này và ghi thẳng được. Helper tự nhận biết.
- Máy để bàn không có pin: ẩn dòng pin và ghi chú gập nắp.
- Đã thử thật trên MacBook Pro 14" M4 Pro, macOS 27. Các dòng khác dựa trên cách dò ở trên, chưa thử trực tiếp.

## Vì sao cần helper chạy root

macOS chỉ cho root ghi vào SMC, nơi đặt tốc độ quạt. Lần đầu bấm "Cài quyền điều khiển quạt", macOS hỏi mật khẩu rồi cài:

- `/Library/PrivilegedHelperTools/com.tai.macpulse.fanhelper`
- `/Library/LaunchDaemons/com.tai.macpulse.fanhelper.plist`
- `/Library/Application Support/MacPulse/fan-request` (file app ghi yêu cầu, helper đọc mỗi giây)
- Log: `/Library/Logs/MacPulseFanHelper.log`

Helper hiểu ba lệnh: `auto`, `manual <phần trăm> <thời điểm>` và `smart <bắt đầu> <tối đa> <chốt nóng> <% khi chạm chốt> <độ trễ °C> <giây chờ> <thời điểm>`. App gửi lại lệnh mỗi 5 giây. Nếu quá 20 giây không nhận được (app tắt, treo, máy ngủ dậy) thì helper trả quạt về Tự động. Thoát app bình thường thì quạt về Tự động ngay. SMC từ chối lệnh trả quạt (thường lúc máy ngủ) thì helper thử lại mỗi giây.

Thủ công: khi chip chạm 110°C, quạt không chạy dưới 50%. Lúc thử render video, macOS ở chế độ Tự động để chip 114°C mà quạt chỉ chạy khoảng 45%, nên sàn 50% vẫn mát hơn mặc định. Nguội dưới 100°C thì quạt về đúng mức bạn đặt.

## Quạt Thông minh

Ngưỡng lấy từ nghiên cứu ở `docs/nhiet-do-m4pro.md`, chốt an toàn chỉnh lại theo số đo trên máy.

| Mức | Bắt đầu tăng | Tối đa | Chốt điểm nóng nhất | Trả quyền cho macOS |
|---|---|---|---|---|
| Êm | 82°C | 102°C | 116°C → quạt ≥ 70% | dưới 77°C đủ 20 giây |
| Cân bằng (mặc định) | 72°C | 95°C | 114°C → 100% | dưới 68°C đủ 15 giây |
| Mát | 60°C | 88°C | 112°C → 100% | dưới 57°C đủ 10 giây |

- Nhiệt điều khiển là giá trị lớn hơn giữa trung bình nhân CPU và trung bình GPU, làm mượt khoảng 8 giây.
- Helper chỉ giành quyền khi đường cong đòi quạt nhanh hơn mức macOS đang chạy (hơn 5%) trong 3 giây liền, nên không bao giờ làm quạt yếu hơn mặc định.
- Quạt tăng tối đa 600 vòng/phút mỗi giây, giảm tối đa 150 vòng/phút mỗi giây.
- macOS báo căng nhiệt (`ProcessInfo.thermalState` từ mức serious) thì quạt chạy hết cỡ.
- Chế độ Thông minh được nhớ qua các lần mở app; Thủ công thì luôn về Tự động khi mở lại.

Sửa code helper rồi build lại thì tab Quạt hiện nút "Cập nhật" để cài bản mới (hỏi mật khẩu lại).

## Gỡ hẳn

1. Nút bánh răng, chọn "Gỡ quyền điều khiển quạt" (hỏi mật khẩu, quạt về Tự động).
2. Tắt "Mở cùng máy", rồi "Thoát MacPulse".
3. Xóa `~/Applications/MacPulse.app`.

## Tệp mã nguồn

| Tệp | Việc |
|---|---|
| `Sources/SMC.swift` | Đọc/ghi SMC qua IOKit (dùng chung cho app và helper) |
| `Sources/Sensors.swift` | CPU, RAM, GPU, nhiệt độ, quạt |
| `Sources/Processes.swift` | Danh sách tiến trình qua `/bin/ps`, thoát tiến trình |
| `Sources/Monitor.swift` | Lấy mẫu định kỳ: 3 giây khi bảng đóng, 1,5 giây khi mở |
| `Sources/FanControl.swift` | Ghi yêu cầu quạt, cài/gỡ helper |
| `Sources/UI.swift` | Giao diện SwiftUI |
| `Sources/main.swift` | Icon thanh menu, cài đặt, khởi động cùng máy |
| `Sources/Tasks.swift`, `Sources/ProcInfo.swift` | Tab Tác vụ: đọc nhật ký Claude, ước tính % ffmpeg |
| `Sources/Power.swift` | Giữ máy thức, hẹn giờ, bảng đếm ngược |
| `Sources/UITasks.swift` | Giao diện tab Tác vụ và Hẹn giờ |
| `Helper/main.swift` | Helper root: quạt Thủ công/Thông minh, dự phòng tắt máy |
| `docs/nhiet-do-m4pro.md` | Nghiên cứu nhiệt độ cho máy này, kèm số đo thực tế |
| `tools/make-icon.swift` | Vẽ icon app |

Lưu ý khi build: SDK macOS 27 biến `@State` của SwiftUI thành macro, mà Command Line Tools không có plugin cho macro đó. Trạng thái cục bộ của view vì thế giữ trong `ViewState` (ObservableObject) thay cho `@State`.

Máy có cài sẵn Macs Fan Control. Đừng cho hai app cùng điều khiển quạt một lúc, chúng sẽ giành nhau.
