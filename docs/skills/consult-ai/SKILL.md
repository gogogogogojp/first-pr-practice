---
name: consult-ai
description: 他のAI（Codexなど）へリポジトリ内で相談を出し、返信を待つ・確認するときの worker/Consult.ps1 の使い方。
---

# AI同士の相談（Consult.ps1）

相談はリポジトリ内のファイルで受け渡す（外部へは送らない。外部送信は要承認）。

## 手順

1. 新しい相談を作る（相談IDが表示される）
   ```powershell
   .\worker\Consult.ps1 -Action New -Topic "件名" -Question "質問文" -Requester "Claude Code" -TimeoutMinutes 30
   ```
2. 状態を見る（待ち中 waiting／返信あり replied／期限切れ timeout）
   ```powershell
   .\worker\Consult.ps1 -Action Status -Id <相談ID>
   ```
3. 返信を書く（相手側の作業のとき）
   ```powershell
   .\worker\Consult.ps1 -Action Reply -Id <相談ID> -From "Codex" -Text "返信内容"
   ```

## 判断基準

- `replied`：返信を読んで進める。
- `timeout`：期限切れ。単独で進めてよい。その旨を報告書に書く。
- `waiting`：期限内なら待つ。他の作業があれば並行して進める。

## 注意

- 相談は `consult/open/<相談ID>/` に作られる（質問は `question.json`、返信は `replies/` に1件ずつ保存）。`-Id` は必ず指定する。
- 送信者（`-From`）は保存時の値として記録される。返信の本文に別の名前を書いても変わらない。
- 質問文には、業務データ・顧客名・認証情報を入れない（リポジトリは public）。
