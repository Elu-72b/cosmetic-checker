# 詳細実装プラン — 化粧品成分チェッカー

各フェーズに「やること・コード例・完了条件」を記載した詳細版です。
上から順に進めれば、常に動く状態を保ちながら完成に近づけます。

---

## 全体アーキテクチャ

```
[スマホカメラ] → 画像アップロード
      │ (メモリ上でのみ処理・保存しない)
      ▼
[Rails 8] ── Gemini Flash API ──→ 成分名リスト抽出
      │
      ▼
[検索フロー] 完全一致 → あいまい検索(pg_trgm) → Gemini APIで生成
      │                                              │
      │                                              ▼
      │                                    PostgreSQLに保存(キャッシュ)
      ▼
[表示] 危険度1(緑)〜5(赤)の色分け一覧 → タップで詳細モーダル
```

### Git運用ルール(全フェーズ共通)

- フェーズ0のみ main へ直接コミット。フェーズ1以降は **1フェーズ=1ブランチ=1PR**
- 1コミット=1つの意味のある変更。`db:migrate` 後は `db/schema.rb` も、gem追加時は `Gemfile.lock` も必ずセットでコミット
- 各フェーズ末尾の「🔀 ブランチとコミット計画」の順に進めればOK
- フェーズ完了時の流れ:

```bash
git push -u origin <ブランチ名>   # GitHubでPRを作成しmainへマージ
git switch main && git pull       # ローカルのmainを最新化
git branch -d <ブランチ名>        # マージ済みブランチを削除
```

---

## フェーズ0: 環境構築(目安: 半日)

### 0-1. プロジェクト作成

```bash
rails new cosmetic-checker -d postgresql --css tailwind
cd cosmetic-checker
mkdir docs
# README.md をルートに上書き、IMPLEMENTATION_PLAN.md を docs/ へ配置
```

### 0-2. Docker設定

`Dockerfile`(開発用の最小構成):

```dockerfile
FROM ruby:3.3
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
```

`compose.yml`:

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: password
    volumes:
      - pg_data:/var/lib/postgresql/data
  web:
    build: .
    ports:
      - "3000:3000"
    volumes:
      - .:/app
    depends_on:
      - db
    env_file:
      - .env
volumes:
  pg_data:
```

`config/database.yml` の development に `host: db` / `username: postgres` / `password: password` を設定。

### 0-3. 環境変数

```bash
# Gemfile に追加
gem "dotenv-rails", groups: [:development, :test]
```

`.env` を作成し `GEMINI_API_KEY=xxxx` を記載。
**必ず `.gitignore` に `.env` があることを確認してからコミットする。**

### 0-4. Git / GitHub連携とコミット計画

フェーズ0はリポジトリ作成直後のため、mainへ直接コミットします。

| #   | コミットメッセージ                          | 対象ファイル                                                          |
| --- | ------------------------------------------- | --------------------------------------------------------------------- |
| 1   | `初期セットアップ: Rails 8プロジェクト作成` | `rails new` が生成した全ファイル                                      |
| 2   | `docs: READMEと実装プランを追加`            | `README.md` / `docs/IMPLEMENTATION_PLAN.md` / `docs/DETAILED_PLAN.md` |
| 3   | `Docker開発環境を構築`                      | `Dockerfile` / `compose.yml` / `config/database.yml`                  |
| 4   | `dotenv-railsを導入しAPIキーを環境変数化`   | `Gemfile` / `Gemfile.lock` / `.gitignore`(**`.env` は含めない**)      |

コミット例(2番目。他も同じ要領):

```bash
git add README.md docs/
git commit -m "docs: READMEと実装プランを追加"
```

全コミット後にGitHubへ接続:

```bash
git remote add origin git@github.com:<ユーザー名>/cosmetic-checker.git
git branch -M main
git push -u origin main
```

### ✅ 完了条件

- `docker compose up` で http://localhost:3000 にRails初期画面が表示される
- GitHubにpushされ、READMEがトップに表示されている

---

## フェーズ1: 成分DBの土台(目安: 1日)

### 1-1. マイグレーション

```bash
bin/rails g model Ingredient name:string inci_name:string risk_level:integer \
  purpose:string description:text ai_generated:boolean source:string source_url:string
```

生成されたマイグレーションを調整:

```ruby
class CreateIngredients < ActiveRecord::Migration[8.0]
  def change
    create_table :ingredients do |t|
      t.string  :name, null: false
      t.string  :inci_name
      t.integer :risk_level, null: false, default: 3
      t.string  :purpose
      t.text    :description
      t.boolean :ai_generated, null: false, default: false
      t.string  :source
      t.string  :source_url
      t.timestamps
    end
    add_index :ingredients, :name, unique: true
  end
end
```

### 1-2. pg_trgm(あいまい検索)

```bash
bin/rails g migration EnablePgTrgm
```

```ruby
class EnablePgTrgm < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pg_trgm"
    add_index :ingredients, :name, using: :gin, opclass: :gin_trgm_ops, name: "index_ingredients_on_name_trgm"
  end
end
```

### 1-3. モデル

```ruby
# app/models/ingredient.rb
class Ingredient < ApplicationRecord
  validates :name, presence: true, uniqueness: true
  validates :risk_level, inclusion: { in: 1..5 }

  # 表記ゆれに対応するあいまい検索(類似度順)
  def self.fuzzy_search(query)
    where("name % :q OR inci_name % :q", q: query)
      .order(Arel.sql(sanitize_sql_array(["similarity(name, ?) DESC", query])))
  end
end
```

### 1-4. seedデータ(公的リスト第1弾)

`db/seeds.rb` に旧表示指定成分(法令由来・約100成分)を投入。
最初は代表的な10〜20件を手で入れて動作確認し、後から拡充でOK。

```ruby
[
  { name: "パラベン", inci_name: "Paraben", risk_level: 3,
    purpose: "防腐剤", source: "旧表示指定成分(厚生省告示)", ai_generated: false },
  # ...
].each { |attrs| Ingredient.find_or_create_by!(name: attrs[:name]) { |i| i.assign_attributes(attrs) } }
```

### 1-5. 危険度基準のドキュメント化

`docs/RISK_CRITERIA.md` を作成し「何を根拠に1〜5へ振り分けるか」を明文化
(例: 1=公的リストで安全性懸念の記載なし … 5=旧表示指定成分かつアレルギー報告多数、など)。
アプリ内の「危険度について」ページから参照する。

### 🔀 ブランチとコミット計画

```bash
git switch -c feature/phase1-ingredients-db
```

| #   | コミットメッセージ                                     | 対象ファイル                                                                                  |
| --- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| 1   | `成分テーブルのマイグレーションを作成`                 | `db/migrate/*_create_ingredients.rb` / `db/schema.rb` / `app/models/ingredient.rb` ほか生成物 |
| 2   | `pg_trgm拡張とあいまい検索用インデックスを追加`        | `db/migrate/*_enable_pg_trgm.rb` / `db/schema.rb`                                             |
| 3   | `Ingredientモデルにバリデーションとあいまい検索を実装` | `app/models/ingredient.rb`                                                                    |
| 4   | `旧表示指定成分のseedデータを追加`                     | `db/seeds.rb`                                                                                 |
| 5   | `docs: 危険度判定基準を明文化`                         | `docs/RISK_CRITERIA.md`                                                                       |

→ push → PR → mainへマージ(手順は「Git運用ルール」参照)

### ✅ 完了条件

- `bin/rails db:migrate db:seed` が通る
- `rails console` で `Ingredient.fuzzy_search("ぱらべん")` がヒットする

---

## フェーズ2: 手入力検索と色分け表示(目安: 1〜2日)

### 2-1. ルーティング

```ruby
# config/routes.rb
root "ingredients#index"
resources :ingredients, only: [:index, :show] do
  collection { get :search }
end
```

### 2-2. コントローラ

```ruby
# app/controllers/ingredients_controller.rb
class IngredientsController < ApplicationController
  def index; end

  def search
    @ingredients = Ingredient.fuzzy_search(params[:q].to_s.strip)
    render :index
  end

  def show
    @ingredient = Ingredient.find(params[:id])
    # Turbo Frame でモーダル表示
  end
end
```

### 2-3. 危険度→色のヘルパー

```ruby
# app/helpers/ingredients_helper.rb
module IngredientsHelper
  RISK_COLORS = {
    1 => "bg-green-500",
    2 => "bg-lime-400",
    3 => "bg-yellow-400",
    4 => "bg-orange-400",
    5 => "bg-red-500"
  }.freeze

  def risk_color_class(level)
    RISK_COLORS.fetch(level, "bg-gray-300")
  end
end
```

### 2-4. ビュー(一覧と詳細モーダル)

一覧はバッジ状に成分名を並べる:

```erb
<%# app/views/ingredients/index.html.erb %>
<%= form_with url: search_ingredients_path, method: :get do |f| %>
  <%= f.text_field :q, placeholder: "成分名を入力", class: "border rounded px-3 py-2" %>
  <%= f.submit "検索", class: "bg-blue-600 text-white rounded px-4 py-2" %>
<% end %>

<div class="flex flex-wrap gap-2 mt-4">
  <% @ingredients&.each do |ing| %>
    <%= link_to ing.name, ingredient_path(ing),
        data: { turbo_frame: "modal" },
        class: "#{risk_color_class(ing.risk_level)} text-white rounded-full px-3 py-1" %>
  <% end %>
</div>

<%= turbo_frame_tag "modal" %>
<%= render "shared/disclaimer" %>
```

詳細(`show.html.erb`)は `turbo_frame_tag "modal"` で包み、
成分名・危険度・配合目的・説明・**出典(source / source_url)** を表示。
`ai_generated?` が true のときは「この説明はAIにより生成されています」を併記。

### 2-5. 免責事項パーシャル

```erb
<%# app/views/shared/_disclaimer.html.erb %>
<p class="text-xs text-gray-500 mt-6">
  本アプリの情報は参考情報であり、医学的助言ではありません。
  説明文の一部はAIにより生成されています。肌トラブル等は専門医にご相談ください。
</p>
```

### 🔀 ブランチとコミット計画

```bash
git switch -c feature/phase2-search-ui
```

| #   | コミットメッセージ                           | 対象ファイル                                                                       |
| --- | -------------------------------------------- | ---------------------------------------------------------------------------------- |
| 1   | `成分検索のルーティングとコントローラを追加` | `config/routes.rb` / `app/controllers/ingredients_controller.rb`                   |
| 2   | `危険度を色クラスに変換するヘルパーを追加`   | `app/helpers/ingredients_helper.rb`                                                |
| 3   | `検索フォームと色分けバッジ一覧を実装`       | `app/views/ingredients/index.html.erb`                                             |
| 4   | `Turbo Frameによる成分詳細モーダルを実装`    | `app/views/ingredients/show.html.erb`                                              |
| 5   | `免責事項パーシャルを追加しフッターに表示`   | `app/views/shared/_disclaimer.html.erb` / `app/views/layouts/application.html.erb` |

→ push → PR → mainへマージ

### ✅ 完了条件

- 手入力→検索→色分けバッジ表示→タップで詳細モーダル、が一通り動く
- 詳細に出典が、画面下部に免責事項が表示される

---

## フェーズ3: Gemini API検索+DBキャッシュ(目安: 2〜3日)

### 3-1. HTTPクライアント

```bash
# Gemfile に追加
gem "faraday"
```

### 3-2. Geminiクライアント(サービスクラス)

```ruby
# app/services/gemini_client.rb
class GeminiClient
  ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/%{model}:generateContent"
  MODEL = "gemini-2.5-flash" # 最新のFlash系モデル名は公式ドキュメントで確認

  def initialize(api_key: ENV.fetch("GEMINI_API_KEY"))
    @api_key = api_key
  end

  # テキスト or 画像+テキストを送り、レスポンス本文(文字列)を返す
  def generate(prompt, image_base64: nil, mime_type: "image/jpeg")
    parts = [{ text: prompt }]
    parts << { inline_data: { mime_type: mime_type, data: image_base64 } } if image_base64

    res = Faraday.post(format(ENDPOINT, model: MODEL)) do |req|
      req.params["key"] = @api_key
      req.headers["Content-Type"] = "application/json"
      req.body = { contents: [{ parts: parts }] }.to_json
    end
    raise "Gemini API error: #{res.status}" unless res.success?

    body = JSON.parse(res.body)
    body.dig("candidates", 0, "content", "parts", 0, "text")
  end
end
```

### 3-3. 成分情報の生成プロンプト(JSONで返させる)

````ruby
# app/services/ingredient_generator.rb
class IngredientGenerator
  PROMPT = <<~TEXT
    化粧品成分「%{name}」について、事実に基づく情報を次のJSONのみで返してください。
    前置きやMarkdownの```は不要です。
    {"name": "...", "inci_name": "...", "risk_level": 1〜5の整数,
     "purpose": "配合目的", "description": "100字程度の中立的な説明"}
    危険度は docs/RISK_CRITERIA.md 相当の基準(安全性懸念の少なさ)で判定してください。
    不明な項目は null にしてください。
  TEXT

  def self.call(name)
    raw = GeminiClient.new.generate(format(PROMPT, name: name))
    json = JSON.parse(raw.gsub(/```json|```/, "").strip)
    Ingredient.create!(
      name: json["name"] || name,
      inci_name: json["inci_name"],
      risk_level: json["risk_level"] || 3,
      purpose: json["purpose"],
      description: json["description"],
      ai_generated: true,
      source: "AI生成(Gemini)"
    )
  rescue JSON::ParserError, Faraday::Error, RuntimeError => e
    Rails.logger.error("成分生成失敗: #{name} / #{e.message}")
    nil
  end
end
````

### 3-4. 検索フロー本体(キャッシュ戦略の中核)

```ruby
# app/services/ingredient_lookup.rb
class IngredientLookup
  # ① 完全一致 → ② あいまい検索 → ③ API生成して保存
  def self.call(name)
    normalized = name.strip
    return nil if normalized.blank?

    Ingredient.find_by(name: normalized) ||
      Ingredient.fuzzy_search(normalized).first ||
      IngredientGenerator.call(normalized)
  end
end
```

コントローラの `search` をこのサービス経由に差し替える。
**②まででヒットすればAPIは呼ばれない = API利用量の節約**がここで効く。

### 3-5. エラー時のUI

生成に失敗した成分は「情報を取得できませんでした」とグレー表示し、アプリ全体は止めない。

### 🔀 ブランチとコミット計画

```bash
git switch -c feature/phase3-gemini-cache
```

| #   | コミットメッセージ                     | 対象ファイル                                                                      |
| --- | -------------------------------------- | --------------------------------------------------------------------------------- |
| 1   | `faradayを導入`                        | `Gemfile` / `Gemfile.lock`                                                        |
| 2   | `Gemini APIクライアントを実装`         | `app/services/gemini_client.rb`                                                   |
| 3   | `成分情報をAI生成するサービスを実装`   | `app/services/ingredient_generator.rb`                                            |
| 4   | `キャッシュ優先の成分検索フローを実装` | `app/services/ingredient_lookup.rb` / `app/controllers/ingredients_controller.rb` |
| 5   | `生成失敗時のエラー表示を追加`         | `app/views/ingredients/index.html.erb`                                            |

→ push → PR → mainへマージ

### ✅ 完了条件

- DBにない成分名を検索すると、自動生成されてDBに保存される
- 同じ成分を2回目に検索したとき、APIが呼ばれない(logで確認)
- `ai_generated: true` の成分詳細に「AI生成」の注記が出る

---

## フェーズ4: カメラ読み取り(目安: 2日)

### 4-1. アップロードフォーム

```erb
<%# app/views/scans/new.html.erb %>
<%= form_with url: scans_path, multipart: true do |f| %>
  <%# capture属性でスマホのカメラを直接起動 %>
  <%= f.file_field :image, accept: "image/*", capture: "environment",
      class: "block" %>
  <%= f.submit "成分表を解析", class: "bg-blue-600 text-white rounded px-4 py-2 mt-2" %>
<% end %>
```

### 4-2. 画像→成分名リスト抽出(メモリ上のみで処理)

````ruby
# app/controllers/scans_controller.rb
class ScansController < ApplicationController
  EXTRACT_PROMPT = <<~TEXT
    この画像は化粧品の全成分表示です。成分名をJSON配列のみで返してください。
    例: ["水", "グリセリン", "BG"]
    前置きやMarkdownは不要。読み取れない場合は [] を返してください。
  TEXT

  def new; end

  def create
    uploaded = params[:image]
    return redirect_to new_scan_path, alert: "画像を選択してください" if uploaded.blank?

    base64 = Base64.strict_encode64(uploaded.read) # ← 保存せずメモリ上で処理
    raw = GeminiClient.new.generate(EXTRACT_PROMPT,
                                    image_base64: base64,
                                    mime_type: uploaded.content_type)
    names = JSON.parse(raw.gsub(/```json|```/, "").strip)

    @results = names.map { |n| IngredientLookup.call(n) }
    @not_found = names.zip(@results).select { |_, r| r.nil? }.map(&:first)
    @ingredients = @results.compact
    render :result
  rescue JSON::ParserError
    redirect_to new_scan_path, alert: "成分表を読み取れませんでした。明るい場所で再撮影してください。"
  end
end
````

ルーティングに `resources :scans, only: [:new, :create]` を追加。
結果画面 `result.html.erb` はフェーズ2の色分けバッジ表示を再利用(パーシャル化推奨)。

### 4-3. 注意点

- 大量成分(30件超)の初回スキャンはAPI呼び出しが連続する → 1件ずつ `IngredientLookup` に通し、失敗はスキップ
- 画像サイズが大きいとタイムアウトしやすい → クライアント側で圧縮するか、Geminiに送る前にリサイズ(後で改善でOK)

### 🔀 ブランチとコミット計画

```bash
git switch -c feature/phase4-camera-scan
```

| #   | コミットメッセージ                             | 対象ファイル                                                                                                              |
| --- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| 1   | `スキャンのルーティングと撮影フォームを追加`   | `config/routes.rb` / `app/controllers/scans_controller.rb` / `app/views/scans/new.html.erb`                               |
| 2   | `画像から成分名を抽出する処理を実装`           | `app/controllers/scans_controller.rb`                                                                                     |
| 3   | `バッジ一覧をパーシャル化し解析結果画面を実装` | `app/views/ingredients/_badge_list.html.erb` / `app/views/scans/result.html.erb` / `app/views/ingredients/index.html.erb` |
| 4   | `読み取り失敗時のエラーハンドリングを追加`     | `app/controllers/scans_controller.rb`                                                                                     |

→ push → PR → mainへマージ

### ✅ 完了条件

- スマホで撮影→解析→色分け一覧→タップで詳細、が一気通貫で動く
- サーバー上に画像ファイルが残っていない(`Active Storage`未使用・tmp未保存)

---

## フェーズ5: デプロイと仕上げ(目安: 1日)

### 5-1. Render用ビルドスクリプト

```bash
# bin/render-build.sh
#!/usr/bin/env bash
set -o errexit
bundle install
bin/rails assets:precompile
bin/rails db:migrate
```

```bash
chmod +x bin/render-build.sh
```

### 5-2. Renderでの設定

1. Render ダッシュボード → New → **PostgreSQL** を作成(Internal Database URL を控える)
2. New → **Web Service** → GitHubリポジトリを連携
   - Build Command: `bin/render-build.sh`
   - Start Command: `bin/rails server`
3. Environment に設定:
   - `DATABASE_URL` = PostgreSQLのInternal URL
   - `RAILS_MASTER_KEY` = `config/master.key` の中身
   - `GEMINI_API_KEY`
   - `RAILS_ENV=production`

### 5-3. 本番確認チェックリスト

- [ ] スマホ実機でカメラ起動〜解析まで動く
- [ ] 免責事項・出典表記が全ページで表示される
- [ ] 初回デプロイ後に `db:seed` を実行(RenderのShellから)
- [ ] READMEに公開URLを追記

### 🔀 ブランチとコミット計画

```bash
git switch -c feature/phase5-deploy
```

| #   | コミットメッセージ               | 対象ファイル                          |
| --- | -------------------------------- | ------------------------------------- |
| 1   | `Render用ビルドスクリプトを追加` | `bin/render-build.sh`                 |
| 2   | `本番向け設定を調整`             | `config/environments/production.rb`   |
| 3   | `docs: READMEに公開URLを追記`    | `README.md`(デプロイ完了後にコミット) |

→ push → PR → mainへマージ

### ✅ 完了条件

- 公開URLで全機能が動作する

---

## 補足

### テスト方針(最小限)

- モデル: バリデーションと `fuzzy_search` のテスト(minitest)
- サービス: `IngredientLookup` を「DBヒット時にAPIを呼ばない」観点でテスト
  (`GeminiClient` をスタブ化。WebMock導入は余裕があれば)

### 将来の拡張候補(今はやらない)

- Redisを挟んだ三層キャッシュ(Redis → PostgreSQL → API)
- 成分テーブルの正規化(出典テーブル・カテゴリテーブルの分離)
- CosIng等からの一括インポートバッチ
- スキャン履歴機能(ログイン導入後)

### 迷ったときの原則

- フェーズ2まで(APIなし)の状態を常に動く形で維持する
- 1フェーズ=1ブランチ=1PR。動いたらマージしてから次へ
