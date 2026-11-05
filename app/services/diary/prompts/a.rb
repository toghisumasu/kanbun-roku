require "digest"
require "json"

module Diary
  module Prompts
    # A（人間の記録）の指示文・JSON スキーマ・生成の設定。入力は「人間の発言」ブロックだけ（Claude の発言は入れない）。
    #
    # PROMPT_VERSION は手で上げる。指示文・スキーマ・設定のハッシュ（fingerprint）を期待値にしたテストがあり、
    # 変えて版を上げ忘れると、テストが落ちる（test/services/diary/prompts/a_test.rb）。
    # 印の文言と数値は、SegmentChunker と Rules の定数から組み立てる（ずれを防ぐため）。
    module A
      PROMPT_VERSION = "A-2026-11-05.1"

      # Ollama に渡す設定。seed と keep_alive は、呼び出す側（座ごと・環境ごと）が決める。
      OPTIONS = { num_ctx: 16_384, temperature: 0.2, num_predict: 3_000 }.freeze

      ITEM_SCHEMA = {
        type: "object",
        properties: { "本文" => { type: "string" }, "引用" => { type: "string" } },
        required: %w[ 本文 引用 ]
      }.freeze

      SCHEMA = {
        type: "object",
        properties: Rules::HEADINGS.to_h { |h| [ h, { type: "array", maxItems: Rules::MAX_ITEMS.fetch(h), items: ITEM_SCHEMA } ] },
        required: Rules::HEADINGS
      }.freeze

      INSTRUCTION = <<~TEXT.freeze
        あなたは会話の記録係です。次の入力は、ある日の【人間】（ユーザー）の発言だけを、時刻つきで時刻順に並べたものです。この入力から、人間の記録をJSONで書いてください。
        ・入力にあることだけを書いてください。入力にないことは書かないでください。数字、固有名詞、URL、ハッシュなどの識別子は、入力の文字列をそのまま写してください。
        ・次の4つの配列に分けます。
          「人間の依頼・共有」…人間がClaudeに何かを求めた（「〜してください」「〜を教えて」「〜をお願いします」など）、または資料・結果を共有した。この2つに限る。質問は「未解決」、意見は「人間の考え」に書く。人間が自分で何かをすると表明したもの（「〜します」「〜に引き継ぎます」など）は、Claudeへの依頼ではないので、ここに書かない。話題のまとまりごとに1項目。最大#{Rules::MAX_ITEMS.fetch("人間の依頼・共有")}つ。
          「決定」…次の2つを書く。
            ・人間が自分の行動・方針を表明した（「〜します」「〜することにします」「〜にします」「〜でいきます」。自分が引き継ぐ・連携すると述べたものを含む）。
            ・人間が、選択肢から選んだ、またはClaudeの案を受け入れた（「〜でいい」「それでいい」、「Q:」「A:」の形式の「A:」の行など）。入力にはClaudeの案そのものは見えない。見えない案の内容を補わず、人間の言葉のとおりに書く。
            次のものは決定に書かない。仮定（「〜とします」）、予定や見込みを述べただけのもの、見解の中に出る「決定」「勝負」などの語、「〜と思いますが」のような弱い意図（これらは「人間の考え」に書く）。Claudeに物や作業を求める言い方（「〜をお願いします」「〜してください」）は依頼であり、決定ではない。「A:」の行は、人間が選んだ決定として必ずここに書き（「人間の考え」には書かない）、引用は「A:」の行から写す。最大#{Rules::MAX_ITEMS.fetch("決定")}つ。
          「人間の考え」…人間が自分の見方・推測・感想・評価を述べた。事実の報告や依頼は含めない。決定は除く。最大#{Rules::MAX_ITEMS.fetch("人間の考え")}つ。
          「未解決」…人間がまだ答えの出ていない疑問や課題として述べたもの。最大#{Rules::MAX_ITEMS.fetch("未解決")}つ。
        ・各項目は「本文」（現代日本語）と「引用」の2つのキーを持ちます。引用は、本文を直接裏づける人間の発言の一部を、#{Rules::QUOTE_MAX_CHARS}文字以内で、言い換えずにそのまま写します。文末の短い断片（#{Rules::SHORT_QUOTE_CHARS}文字未満）だけの引用にしないでください。
        ・「本文」は、人間が表明したことを「依頼した」と書かないでください。人間が自分でやると言ったことは「〜すると表明した」「〜することにした」と書き、Claudeに求めたことだけを「依頼した」と書いてください。
        ・なければ空の配列でよい。件数を合わせるために書かないでください。同じ内容を複数の見出しに書かないでください。
        ・「#{SegmentChunker::CLAUDE_PASTE_MARK}」は、人間がClaudeの文を貼った箇所を示す印です。印の内容は、人間の依頼・決定・考えにしないでください。引用にも印を含めないでください。印の前後にある人間の文だけを根拠にしてください。
        ・本文が「#{SegmentChunker::MEDIA_MARKS.fetch(:image)}」「#{SegmentChunker::MEDIA_MARKS.fetch(:document)}」「#{SegmentChunker::EMPTY_MARK}」などの印だけの発言については、本文を「#{Rules::EXEMPT_PHRASE}」とし、引用は空の文字列にしてください。
      TEXT

      class << self
        # 指示文・スキーマ・設定のハッシュ（先頭16桁）。
        def fingerprint
          Digest::SHA256.hexdigest([ INSTRUCTION, JSON.generate(SCHEMA), JSON.generate(OPTIONS) ].join("\n---\n"))[0, 16]
        end
      end
    end
  end
end
