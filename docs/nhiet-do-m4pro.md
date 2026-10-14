# Nhiệt độ và đường cong quạt cho MacBook Pro 14" M4 Pro (Mac16,8)

## Nguồn

1. Apple, thông số MBP 14" M4 Pro/Max: https://support.apple.com/en-us/121553
2. Apple, nhiệt độ vận hành Mac laptop: https://support.apple.com/en-us/102336
3. Apple, tuổi thọ pin: https://www.apple.com/batteries/maximizing-performance/
4. Apple, chế độ năng lượng (High Power): https://support.apple.com/HT212852
5. Apple Newsroom, M4 Pro/M4 Max: https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/
6. Apple, tài liệu thay quạt MBP 14" M4 Pro/Max: https://support.apple.com/en-us/120773
7. Notebookcheck, MBP 14 M4 Pro bản 12 nhân/24 GB: https://www.notebookcheck.net/Apple-MacBook-Pro-14-2024-M4-Pro-base-SKU-laptop-review-Who-needs-the-M4-Pro.932642.0.html
8. Notebookcheck, MBP 14 M4 Pro bản 14 nhân: https://www.notebookcheck.net/Apple-MacBook-Pro-14-2024-review-The-M4-Pro-and-matte-display-are-massive-upgrades.914597.0.html
9. Eclectic Light, Power Modes and Apple Silicon GPUs: https://eclecticlight.co/2025/01/06/power-modes-and-apple-silicon-gpus/
10. Eclectic Light, Power and thermal glory: https://eclecticlight.co/2024/02/23/apple-silicon-2-power-and-thermal-glory/
11. Wccftech dẫn số đo của Max Tech: https://wccftech.com/m5-macbook-pro-can-reach-99-degrees-celsius-when-under-load-but-runs-cooler-than-m4/
12. Apple Community, M4 Pro Mac mini (người dùng): https://discussions.apple.com/thread/255854367
13. iFixit Answers, M4 Max 14" (người dùng): https://www.ifixit.com/Answers/View/898490/What+level+of+M4+Max+warming+is+too+much
14. Texas Instruments SPRABX4B: https://www.ti.com/lit/an/sprabx4b/sprabx4b.pdf
15. DfR Solutions, Temperature Cycling and Fatigue: https://smtnet.com/library/files/upload/Temp-Cycling-and-Electronics-Fatigue.pdf
16. Battery University BU-808: https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries
17. Feinauer, Waldmann và cộng sự, J. Power Sources 594 (2024): https://publikationen.bibliothek.kit.edu/1000167711/152096634
18. VAST Data KB, bảng JEDEC JESD218: https://kb.vastdata.com/docs/risk-of-data-retention-on-solid-state-devices-stored-without-power
19. Samsung 990 PRO datasheet: https://download.semiconductor.samsung.com/resources/data-sheet/samsung_nvme_ssd_990_pro_datasheet_rev.2.0.pdf
20. Sanyo Denki, Understanding Fan Life: https://sanyodenki.com/global/america/documents/Sanyo_Denki_America_Understanding_Fan_Life.pdf
21. ebm-papst, công thức L10: https://mag.ebmpapst.com/en/industries/refrigeration-ventilation/l10-formula-for-the-mechanical-service-life-of-fans_22847/
22. Tunabelly, TG Pro trên M4: https://www.tunabellysoftware.com/blog/files/tgpro-m4-fan-control.html
23. macsfancontrol.net (không rõ ai vận hành): https://macsfancontrol.net/
24. FanCurve (GitHub): https://github.com/GeneralWaffels/FanCurve
25. Noctua blog, đường cong quạt: https://www.noctua.at/en/expertise/blog/antec-flux-pro-noctua-edition-recommended-pwm-fan-curves
26. vorssaint-utils issue #2460 (Mac16,8): https://github.com/vorssaint/vorssaint-utils/issues/2460
27. Stanislas blog, thermal pressure trên macOS: https://stanislas.blog/2025/12/macos-thermal-throttling-app/
28. Stats README: https://github.com/exelban/stats

## Sự thật

### Apple công bố gì

Tôi không tìm thấy tài liệu Apple nào nêu Tj max hay ngưỡng throttle của chip M-series. Apple chỉ cho nhiệt độ môi trường 10–35°C [1][2], nói máy "có thể ấm khi dùng bình thường", quạt tự bật, và app bên thứ ba đo nhiệt bên trong chứ không đo vỏ [2]. Với pin, Apple coi 16–22°C là vùng lý tưởng; môi trường trên 35°C "có thể làm hỏng vĩnh viễn dung lượng pin", sạc khi nóng hại thêm [3]. High Power cho quạt quay nhanh hơn để có thể tăng hiệu năng ở tải rất nặng [4]. M4 Pro dùng tiến trình 3 nm thế hệ hai [5]. Quạt thay riêng từng chiếc được, nhưng phải tháo bo mạch chủ [6].

### Số đo trên M4 Pro 14"

Notebookcheck đo đúng bản 12 nhân/24 GB [7]: CPU trung bình 40°C khi nghỉ, 103°C khi chạy CPU+GPU cùng lúc (GPU 87°C). Họ viết Apple "chọn quạt êm và nhiệt cao". Cinebench R15 chạy lặp mất khoảng 11% hiệu năng, kể cả ở High Power. Kê tay tối đa 33°C, giữa bàn phím 47°C, đáy 43°C.

Với bản 14 nhân [8]: quạt Automatic tối đa 44,5 dB(A), High Power 56 dB(A), không đo được khác biệt hiệu năng. SoC vọt 68 W rồi lùi về khoảng 40 W. Họ nhận xét bàn phím 47°C lẽ ra được lợi nếu quạt quay nhanh hơn. Trên M4 Pro Mac mini, High Power không làm đổi xung hay hiệu năng CPU [9].

Max Tech đo một MBP 14" M4 (không rõ bản) chạy Cinebench 2024: trung bình lõi 100,9°C, lõi nóng nhất 114°C [11]. Dữ liệu người dùng (giai thoại): một M4 Pro Mac mini tăng quạt tay từ khoảng 101°C xuống 92°C; một máy khác giữ GPU dưới 90°C ở 67% quạt so với trên 100°C ở 58% [12]. M4 Max 14" có P-core 90–100°C khi tải toàn lõi, quạt trên 5.000 rpm [13].

Trên Mac16,8, SMC có 112 khóa Tp*/Te*; các khóa đi theo cặp trả cùng giá trị, giống số gộp theo cụm. Khóa nóng nhất khoảng 99,9°C trong khi bộ khóa con của một app chỉ thấy 86–87°C. Tác giả đề xuất dùng P95 [26].

Số đo của bạn (trung bình 94–97°C, nóng nhất 110–118°C, quạt 4.800–5.300 rpm) khớp với [7] và [11].

### Độ bền bán dẫn

TI [14]: electromigration là cơ chế hao mòn chính. Chip nhúng công nghiệp của TI thiết kế cho 10 năm chạy liên tục ở Tj 105°C. Hệ số tuổi thọ so với 105°C (Ea 0,7 eV): 100°C ×1,33; 95°C ×1,79; 90°C ×2,43; 85°C ×3,32; 80°C ×4,58. Trên 105°C: 110°C ×0,5, 125°C ×0,2. Tắt máy thì "đồng hồ" hao mòn dừng. Tài liệu không tính phần đóng gói và ghi rằng tiến trình 28 nm trở xuống có thêm điều kiện riêng.

DfR [15]: phần lớn hỏng hóc điện tử đến từ ứng suất nhiệt do chênh lệch giãn nở (CTE). JESD47 mô hình tuổi thọ mối hàn theo Coffin–Manson ΔT^n với n=2.

### Pin, SSD, quạt

BU-808 [16], lưu trữ 1 năm: 25°C còn 96% (sạc 40%) hoặc 80% (sạc 100%); 40°C còn 85% hoặc 65%. Không có hàng 35°C hay 45°C. Feinauer và cộng sự [17], cell pouch sạc xả liên tục: 25°C đạt 2.851 chu kỳ tới 80% SOH, 45°C chỉ 946 chu kỳ. Số 35°C nằm trong hình, tôi không trích được.

SSD: lớp client JESD218 giả định 40°C khi chạy, giữ dữ liệu 1 năm ở 30°C khi tắt [18]; Samsung 990 PRO ghi 0–70°C [19]. Apple không công bố giới hạn nhiệt SSD (không tìm thấy).

Quạt: Sanyo Denki thử L10 ở 100% PWM, đạt 40.000 giờ ở 60°C, coi nhiệt độ là yếu tố giới hạn chính, khuyên giảm tốc hoặc tắt quạt khi không cần [20]. ebm-papst nói tuổi thọ ổ bi phụ thuộc nhiệt độ, tốc độ và dầu mỡ [21]. Không tìm được loại ổ trục quạt Apple dùng.

### Công cụ và thực hành

TG Pro điều khiển được quạt M4 Pro, luật Auto Boost do người dùng tự đặt; tôi không tìm thấy ngưỡng khuyến nghị nào của Tunabelly [22]. macsfancontrol.net gợi ý bắt đầu 50–60°C, tối đa 85–90°C, tránh cảm biến hay giật; trang này cũng nói firmware M3/M4 Pro/Max tắt quạt dưới khoảng 77–80°C, nhưng tự mâu thuẫn và không dẫn nguồn [23]. FanCurve cho chọn lõi nóng nhất, trung bình CPU, GPU hoặc max(CPU, GPU); trễ tắt 3°C, chờ 15 giây mới bật quạt, trên 95°C chạy tối đa [24]. Noctua lấy linh kiện nóng nhất (CPU hoặc GPU) và dùng trễ 5°C/5 giây [25] (trích qua kết quả tìm kiếm vì trang chặn truy cập trực tiếp). Fan control trong Stats ở chế độ legacy, không còn sửa lỗi [28]. thermald phát mức thermal pressure qua thông báo `com.apple.system.thermalpressurelevel`, đọc không cần root [27]; Eclectic Light dẫn khuyến nghị dùng thermal pressure thay vì nhiệt độ để đo căng nhiệt [10].

## Diễn giải (ý kiến của tôi)

95°C trung bình là mức Apple chủ động chọn, không phải sự cố. Nếu giả định chip Apple có ngân sách giống TI (Apple không công bố), 95°C liên tục tương đương khoảng 18 năm chạy 24/7; tải nặng vài giờ mỗi ngày thì còn xa hơn nữa. Hạ từ 95 xuống 85°C nhân tuổi thọ electromigration khoảng 1,85 lần, nhưng là nhân trên một con số vốn đã dài hơn đời máy. Các khóa 110–118°C nằm trong vùng TI giảm định mức, nên tôi muốn chúng chỉ là đỉnh ngắn.

Mỏi mối hàn tăng theo ΔT². Nghỉ 45°C lên tải 95°C so với lên 85°C: hư hại mỗi chu kỳ gấp khoảng (50/40)² ≈ 1,56 lần. ΔT ở mối hàn nhỏ hơn ΔT ở die, nên đây chỉ là chiều hướng. Dao động ±2–3°C do quạt "săn" gần như không đáng kể về mỏi, chỉ gây khó chịu vì tiếng.

Thứ thật sự được lợi khi mát hơn là pin (nóng cộng sạc đầy là tệ nhất), bàn phím 47°C, và có thể vài phần trăm hiệu năng bền. Phần hiệu năng chưa chắc: Notebookcheck không thấy High Power giúp gì. Quạt hao chủ yếu theo nhiệt, tốc độ đứng sau, nhưng thay quạt phải tháo bo mạch, nên đừng để quạt chạy khi máy đang nghỉ.

Về cảm biến: trong số đo của bạn, trung bình thấp hơn khóa nóng nhất 13–24°C. Dùng trung bình (hoặc P90) để lái đường cong vì nó ổn định; dùng khóa nóng nhất làm chốt an toàn.

## Đề xuất cho máy này

Vùng mục tiêu: tải nặng kéo dài giữ CPU trung bình 80–90°C, khóa nóng nhất ≤105°C phần lớn thời gian (chạm 110°C vài giây không sao). Nghỉ 40–60°C, quạt để Apple lo. Pin ≤35°C, SSD dưới 60°C (40–48°C hiện tại là ổn). Tránh vừa chạy nặng vừa giữ pin 100% lâu.

Tín hiệu điều khiển:
- T_cpu = trung bình các khóa Tp*/Te* đọc được (bỏ khóa thiếu, bỏ giá trị ngoài 10–130°C); T_gpu = trung bình Tg*.
- T_ctrl = max(T_cpu, T_gpu), làm mượt EMA τ ≈ 8 giây (α ≈ 0,12 nếu đọc 1 lần/giây).
- T_hot = max mọi khóa, lấy trung vị 3 mẫu, không EMA, chỉ dùng làm chốt an toàn.
- Thermal pressure từ heavy trở lên thì quạt 100%.

| Preset | Bắt đầu tăng | Tối đa (7.826 rpm) | Chốt an toàn T_hot | Trễ khi giảm |
|---|---|---|---|---|
| Êm | 82°C | 102°C | ≥112°C → ≥70% | 5°C, chờ 20 s |
| Cân bằng (mặc định) | 72°C | 95°C | ≥108°C → 100% | 4°C, chờ 15 s |
| Mát | 60°C | 88°C | ≥105°C → 100% | 3°C, chờ 10 s |

Giữa hai mốc nội suy tuyến tính từ 2.317 lên 7.826 rpm. Ở T_ctrl 95°C, preset Êm cho khoảng 5.900 rpm, nhỉnh hơn mức 4.800–5.300 của Apple. Tăng tốc chờ 3 giây, giới hạn tăng ≤600 rpm/s, giảm ≤150 rpm/s. Dưới mốc bắt đầu thì trả quạt về chế độ tự động của Apple thay vì ép tốc tối thiểu. Khi app thoát, crash, máy ngủ, hoặc đọc cảm biến lỗi quá 5 giây, trả quyền về macOS.

Phần chưa biết: chưa có bài đo công khai nào cho MBP 14" M4 Pro với quạt ép tối đa, nên mức hạ nhiệt thật trên máy bạn chưa rõ. Cách kiểm: chạy cùng lệnh ffmpeg 10 phút ở quạt cố định 50%, 75%, 100%, ghi T_cpu, T_hot, nhiệt pin và fps. Nếu 100% chỉ hạ vài độ mà fps không đổi, chọn Cân bằng hoặc Êm. Thêm một phép thử: đặt quạt 50% khi máy đang ở 65°C. Nếu quạt không quay, lời đồn firmware khóa quạt dưới 77–80°C [23] đúng với máy bạn, và preset Mát chỉ có tác dụng từ mốc đó.

## Đo thực tế trên máy này (14/10/2026)

MacPulse đọc cảm biến SMC, cùng một máy Mac16,8:

| Tình huống | Quạt | CPU trung bình | Điểm nóng nhất |
|---|---|---|---|
| Render nặng, macOS tự điều khiển quạt | 4.800–5.300 vòng/phút | 94–97°C | 110–118°C |
| 8 luồng CPU, chế độ Thông minh mức Mát | tăng dần rồi 7.826 vòng/phút | 73–85°C | 99–114°C |
| Render nặng, quạt hết cỡ | 7.826 vòng/phút | 86–91°C | 111–116°C |

Quạt hết cỡ hạ nhiệt trung bình CPU khoảng 6–10°C so với macOS tự điều khiển. Điểm nóng nhất gần như đứng yên ở 110–116°C, vì nó do công suất dồn vào từng nhân chứ không do khả năng làm mát.

Hệ quả cho MacPulse: chốt an toàn theo điểm nóng nhất được nâng từ 105/108/112°C (đề xuất ở trên) lên 112/114/116°C cho các mức Mát/Cân bằng/Êm. Để chốt thấp hơn thì quạt gào hết cỡ suốt lúc tải nặng mà điểm nóng không giảm. Đường cong theo nhiệt trung bình mới là thứ thật sự điều khiển quạt.

Chưa đo: hiệu năng (fps của ffmpeg) có tăng khi quạt hết cỡ hay không. Notebookcheck không thấy khác biệt ở chế độ High Power, nên lợi ích chính của quạt mạnh hơn vẫn là pin và bàn phím mát hơn.
