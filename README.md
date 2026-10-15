# MacPulse

Icon trên thanh menu cho Mac chip Apple. Bấm vào là thấy nhiệt độ, mức tải của máy, tiến trình đang chạy, việc Claude và việc dựng video đang làm tới đâu. App còn điều khiển được quạt và hẹn giờ cho máy ngủ hoặc tắt.

## Tải và cài

1. Vào trang [Releases](https://github.com/TTN0623/MacPulse/releases/latest), tải file `MacPulse-<phiên bản>.dmg`.
2. Mở file .dmg, kéo MacPulse vào thư mục Applications, rồi mở app.
3. Lần đầu macOS báo không mở được, vì app chưa được Apple công chứng. Bấm "Xong", vào **Cài đặt hệ thống › Quyền riêng tư & Bảo mật**, bấm **Vẫn mở** cạnh dòng nhắc tới MacPulse và nhập mật khẩu máy. Chỉ phải làm một lần.

Bản mới: app tự hỏi GitHub mỗi ngày. Có bản mới thì dưới thanh tab hiện dải "Có bản mới", bấm **Cập nhật** là xong. App kiểm chữ ký số trước khi cài, file bị sửa sẽ bị từ chối.

## Máy dùng được

Mọi Mac chip Apple (M1, M2, M3, M4 và mới hơn), macOS 14 Sonoma trở lên. Mac chip Intel không chạy được.

| Dòng máy | Theo dõi | Điều khiển quạt |
|---|---|---|
| MacBook Air | Đủ | Máy không có quạt, tab Quạt chỉ để xem |
| MacBook Pro 13" (M1, M2) | Đủ | 1 quạt |
| MacBook Pro 14", 16" | Đủ | 2 quạt |
| Mac mini, iMac, Mac Studio | Đủ (không có mục pin) | Theo số quạt của máy |

App tự dò cảm biến và số quạt của từng máy. Bản hiện tại được thử thật trên MacBook Pro 14" M4 Pro; các dòng khác chưa thử trực tiếp. Gặp lỗi trên máy nào, hãy mở Issue và ghi tên máy.

## Các tab

| Tab | Làm gì |
|---|---|
| Tổng quan | % CPU từng nhân, GPU, RAM, nhiệt độ CPU/GPU/SSD/pin, công suất, tốc độ quạt, đối chiếu với mức nhiệt khuyến nghị |
| Tiến trình | Xếp theo CPU hoặc RAM, gộp theo ứng dụng; chuột phải để thoát hoặc ghim sang tab Tác vụ |
| Tác vụ | Phiên Claude Code đang làm gì (model, công cụ đang chạy), việc dựng video kèm % và giờ xong dự kiến, việc tải lên/tải xuống qua mạng |
| Quạt | Tự động như macOS; Thông minh tăng quạt khi chip vượt ngưỡng (mức Êm, Cân bằng, Mát); Thủ công |
| Hẹn giờ | Giữ máy thức; ngủ hoặc tắt máy theo giờ hẹn hoặc khi hết việc, có đếm ngược 60 giây |

Ngưỡng nhiệt và các mức quạt dựa trên [bản nghiên cứu nhiệt độ](docs/nhiet-do-m4pro.md), có kèm số đo thực tế.

## Quyền và dữ liệu

- macOS chỉ cho tiến trình quản trị chỉnh quạt, nên tab Quạt cài một helper nhỏ chạy nền (hỏi mật khẩu một lần). Helper đặt tốc độ quạt theo yêu cầu của app và trả quạt về macOS khi app tắt. Nếu bật "Luôn cho phép", helper tự cập nhật khi app có bản mới; nó chỉ nhận bản có chữ ký của MacPulse.
- Mọi số liệu đọc ngay trên máy. Tab Tác vụ đọc nhật ký phiên Claude Code trong `~/.claude/projects` để hiện việc đang làm; không gửi đi đâu.
- App chỉ kết nối mạng để hỏi GitHub có bản mới hay không.

## Gỡ

Nút bánh răng, chọn **Gỡ MacPulse khỏi máy…**. Quạt trở về chế độ mặc định của macOS; helper, mục mở cùng máy và cài đặt đều bị xóa.

## Phát triển

Cách build, phát hành bản mới và cấu trúc mã nằm ở [docs/PHAT-TRIEN.md](docs/PHAT-TRIEN.md).
