require "digest"
require "json"

module Diary
  # 日記の生成の規則（後処理・引用の検証・前処理）の定数と版。DBには触れない。
  #
  # VERSION は手で上げる。ただし、規則の定数のハッシュ（fingerprint）を期待値にしたテストがあり、
  # 定数を変えて VERSION を上げ忘れると、テストが落ちる（test/services/diary/rules_test.rb）。
  # fingerprint には、このファイルの定数のほか、前処理（分類・貼り付けの照合・チャンカー）の定数も含める
  # （前処理が変わると A の入力が変わるため）。
  module Rules
    VERSION = "2026-11-02.2"

    # A の見出し。HEADINGS はスキーマ・保存の順。PRIORITY は重複を落とすときの優先度（高い順）。
    HEADINGS = %w[ 人間の依頼・共有 決定 人間の考え 未解決 ].freeze
    PRIORITY = %w[ 決定 人間の考え 未解決 人間の依頼・共有 ].freeze
    MAX_ITEMS = { "人間の依頼・共有" => 5, "決定" => 5, "人間の考え" => 5, "未解決" => 3 }.freeze

    # 重複除去：見出しをまたいで、本文の文字2-gramの Dice 係数がこの値以上なら重複。優先度の低い側を落とす。
    DICE_THRESHOLD = 0.5

    # 再分類ルール（c）：「決定」の引用がこれらで終わる項目は、依頼とみなして「人間の依頼・共有」へ移す。
    RECLASSIFY_FROM = "決定"
    RECLASSIFY_TO = "人間の依頼・共有"
    RECLASSIFY_ENDINGS = %w[ ください お願いします ますか ].freeze
    # 語尾を見るときに、引用の末尾から取り除く記号・空白。
    QUOTE_TRAILING = /[\s。．.！!？?」』）)]+\z/

    # 引用の検証。
    QUOTE_MAX_CHARS = 40
    SHORT_QUOTE_CHARS = 10
    # 本文がこの語を含み、引用が空の項目は、「引用なし」に数えない（免除）。画像・文書だけの発言のため。
    EXEMPT_PHRASE = "画像・文書を共有した"
    SENTENCE_BOUNDARY = /[。.!！?？\n]/
    LIGHT_STRIP = /[[:space:]*＊`]/

    # 決定項目の候補リンク（直前の assistant 発言）を付ける見出し。
    CANDIDATE_HEADINGS = %w[ 決定 ].freeze
    ITEM_KEY_SEPARATOR = ":"

    # A の入力の塊の分け方。human_only = 「人間の発言」ブロックだけを入力にし、塊も人間の発言の分だけで数える
    # （SegmentChunker の flow: false）。変えると、塊の分かれ方・入力が変わるので、規則の版を上げる。
    A_CHUNK_MODE = "human_only"

    class << self
      # この規則（と、前処理の定数）の内容を、名前つきのハッシュにしたもの。
      def snapshot
        {
          "diary" => {
            "headings" => HEADINGS, "priority" => PRIORITY, "max_items" => MAX_ITEMS,
            "dice_threshold" => DICE_THRESHOLD,
            "reclassify" => [ RECLASSIFY_FROM, RECLASSIFY_TO, RECLASSIFY_ENDINGS, QUOTE_TRAILING.source ],
            "quote" => [ QUOTE_MAX_CHARS, SHORT_QUOTE_CHARS, EXEMPT_PHRASE, SENTENCE_BOUNDARY.source, LIGHT_STRIP.source ],
            "candidate_headings" => CANDIDATE_HEADINGS, "item_key_separator" => ITEM_KEY_SEPARATOR,
            "a_chunk_mode" => A_CHUNK_MODE
          },
          "detector" => { "min_chars" => ClaudePasteDetector::MIN_CHARS, "strip" => ClaudePasteDetector::STRIP.source },
          "classifier" => {
            "paste_min_lines" => MessageClassifier::PASTE_MIN_LINES, "paste_min_chars" => MessageClassifier::PASTE_MIN_CHARS,
            "shell_prompt_min_lines" => MessageClassifier::SHELL_PROMPT_MIN_LINES,
            "patterns" => [ MessageClassifier::SHELL_PROMPT, MessageClassifier::PROMPT_ONLY, MessageClassifier::TILDE_PROMPT,
                            MessageClassifier::PASSWORD_PROMPT, MessageClassifier::PROGRESS ].map(&:source),
            "image_extensions" => MessageClassifier::IMAGE_EXTENSIONS
          },
          "chunker" => {
            "context" => SegmentChunker::CONTEXT, "output_reserve" => SegmentChunker::OUTPUT_RESERVE,
            "template_reserve" => SegmentChunker::TEMPLATE_RESERVE, "input_limit" => SegmentChunker::INPUT_LIMIT,
            "weights" => [ SegmentChunker::HAN_WEIGHT, SegmentChunker::OTHER_WEIGHT, SegmentChunker::ASCII_WEIGHT, SegmentChunker::SAFETY ],
            "assistant_head_chars" => SegmentChunker::ASSISTANT_HEAD_CHARS,
            "paste_lines" => [ SegmentChunker::PASTE_HEAD_LINES, SegmentChunker::PASTE_TAIL_LINES ],
            "quote_max_chars" => SegmentChunker::QUOTE_MAX_CHARS,
            "marks" => [ SegmentChunker::MEDIA_MARKS.transform_keys(&:to_s), SegmentChunker::EMPTY_MARK, SegmentChunker::CLAUDE_PASTE_MARK,
                         SegmentChunker::OMITTED, SegmentChunker::TRUNCATED_MARK, SegmentChunker::MIDDLE_MARK ],
            "labels" => SegmentChunker::LABELS
          }
        }
      end

      # snapshot のハッシュ（先頭16桁）。キーの順に依存しない。data は、テストで別の内容を渡すため。
      def fingerprint(data = snapshot)
        Digest::SHA256.hexdigest(JSON.generate(deep_sort(data)))[0, 16]
      end

      private

      def deep_sort(value)
        case value
        when Hash then value.sort_by { |k, _| k.to_s }.to_h { |k, v| [ k.to_s, deep_sort(v) ] }
        when Array then value.map { |v| deep_sort(v) }
        else value
        end
      end
    end
  end
end
