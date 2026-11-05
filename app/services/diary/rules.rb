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
    VERSION = "2026-11-05.1"

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
    # 決定語（Coverage::DECISION_RE と同じもの。語の定義を二重に持たない）。引用か本文（どちらも NFKC のあと）が含む項目は、
    # 語尾が RECLASSIFY_ENDINGS でも移さず、「決定」に残す（決定と依頼の両方を含む文の可能性があるため）。
    RECLASSIFY_KEEP_PATTERN = Coverage::DECISION_RE
    # 語尾を見るときに、引用の末尾から取り除く記号・空白。
    QUOTE_TRAILING = /[\s。．.！!？?」』）)]+\z/

    # 引用の検証。
    QUOTE_MAX_CHARS = 40
    SHORT_QUOTE_CHARS = 10
    # 本文がこの語を含み、引用が空の項目は、「引用なし」に数えない（免除）。画像・文書だけの発言のため。
    EXEMPT_PHRASE = "画像・文書を共有した"
    # 免除語の言い換え（exempt_paraphrase）。引用が空で、本文がこのいずれかの語を含み、EXEMPT_PARAPHRASE_MAX_CHARS 字以下で、
    # かつ座の入力（その塊の人間の発言）に、印だけの行（MEDIA_ONLY_LINE）が実在するときに免除する。
    EXEMPT_PARAPHRASE_WORDS = %w[ 画像 文書 ].freeze
    EXEMPT_PARAPHRASE_MAX_CHARS = 12
    MEDIA_ONLY_LINE = /\A(?:#{Regexp.union(*SegmentChunker::MEDIA_MARKS.values, SegmentChunker::EMPTY_MARK).source})+\z/
    SENTENCE_BOUNDARY = /[。.!！?？\n]/
    LIGHT_STRIP = /[[:space:]*＊`]/

    # 決定項目の候補リンク（直前の assistant 発言）を付ける見出し。
    CANDIDATE_HEADINGS = %w[ 決定 ].freeze
    ITEM_KEY_SEPARATOR = ":"

    # 引用の原文化（QuoteRestorer）。保存する引用を、人間の発言の原文の該当範囲に置き換える。変えると保存内容が変わる。
    QUOTE_RESTORE = "earliest_message_first_match_trailing_punct"

    # 短い貼り付けの行規則（ClaudePasteDetector）。正規化後この字数以上の行が、同じ会話の先行する assistant に完全に含まれ、
    # 先行する user 発言に同じ行が無ければ、印に置き換える。発言の空でない行の全部が該当するときは置き換えない。
    LINE_PASTE_MIN_CHARS = ClaudePasteDetector::LINE_MIN_CHARS

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
            "reclassify" => [ RECLASSIFY_FROM, RECLASSIFY_TO, RECLASSIFY_ENDINGS, QUOTE_TRAILING.source, RECLASSIFY_KEEP_PATTERN.source ],
            "quote" => [ QUOTE_MAX_CHARS, SHORT_QUOTE_CHARS, EXEMPT_PHRASE, SENTENCE_BOUNDARY.source, LIGHT_STRIP.source,
                         EXEMPT_PARAPHRASE_WORDS, EXEMPT_PARAPHRASE_MAX_CHARS, MEDIA_ONLY_LINE.source ],
            "candidate_headings" => CANDIDATE_HEADINGS, "item_key_separator" => ITEM_KEY_SEPARATOR,
            "a_chunk_mode" => A_CHUNK_MODE, "quote_restore" => QUOTE_RESTORE
          },
          "detector" => {
            "min_chars" => ClaudePasteDetector::MIN_CHARS, "strip" => ClaudePasteDetector::STRIP.source,
            "line_paste" => [ LINE_PASTE_MIN_CHARS, "session_assistant_contains_and_no_prior_user_line_and_not_all_lines" ]
          },
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
