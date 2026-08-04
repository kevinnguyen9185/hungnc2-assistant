# Agent bootstrap — repo hungnc2-assistant (blueprint tổng)

- Bộ nhớ dài hạn = repo brain: `workspace/brain/` (hoặc clone từ
  https://github.com/my-agents-090185/brain). Đọc `README.md`,
  `conventions.md` trong đó trước khi làm việc.
- `workspace/` bị gitignore ở repo này — bên trong là các git repo RIÊNG
  (brain, projects/za-*...). Sửa gì trong đó phải theo luật của brain:
  `git pull --rebase` TRƯỚC khi sửa, commit + push SAU khi xong,
  danh tính worker theo `conventions.md`.
- Không ghi secret vào brain hay vào chat. Token nằm trong `.env`
  (tham chiếu tên biến, không in giá trị).
