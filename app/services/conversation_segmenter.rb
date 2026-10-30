# 1つの会話（同じ session_id）の発言を区切りに分ける。DBには触れない。
# 発言は occurred_at, id の順に渡す。要素は role / body / occurred_at / id に答えるもの。
#
# 規則の切り替え（PHRASE_RULE_FROM の前後）は、発言ごとの occurred_at で決める。
# 境界をまたぐ区切りは分けない。
#
# 末尾が終了の合図の user 発言で終わる区切りは、返答がまだ入っていないので open として扱う
# （続きが入ったら計算し直す）。最後の発言から GAP 以上、now からたっていれば、返答がなくても閉じる。
#
# 合図のない末尾の区切りも、最後の発言から GAP 以上たっていれば gap で閉じる。
#
# 更新の単位: end_reason が open の区切りだけを、その先頭の発言から後ろの発言で計算し直す
# （閉じた区切りは更新しない）。区切りは先頭の発言から前向きに決まるので、
# 開いた区切りの先頭以降だけを渡しても、全体を渡した結果と同じになる。
class ConversationSegmenter
  JST = ActiveSupport::TimeZone["Asia/Tokyo"]

  # この日時（JST）より前は間隔で、以降は合図の言葉で区切る。
  PHRASE_RULE_FROM = JST.local(2026, 10, 30)
  GAP = 6.hours

  # 終了の合図（人間の発言全体への一致）。足すときはここに加える。
  END_PHRASES = %w[ こちらからは以上です 中断します おやすみなさい さようなら いってきます ].freeze
  RESUME_PHRASE = "再開します".freeze

  # 終了の合図にする発言の長さの上限（前後の空白を除いた文字数）。長い発言に語が混ざっても終了にしない。
  END_PHRASE_MAX_LENGTH = 40

  START_REASONS = %w[ first gap after_end resume_phrase ].freeze
  END_REASONS = %w[ gap end_phrase implicit open ].freeze

  Result = Struct.new(:messages, :start_reason, :end_reason, :continued_from_index, keyword_init: true) do
    def resumed? = start_reason == "resume_phrase"
    def started_at = messages.first.occurred_at
    def ended_at = messages.last.occurred_at
    def segment_date = started_at.in_time_zone(JST).to_date
  end

  # 空白・句点・感嘆符の差は無視する。
  def self.normalize(text)
    text.to_s.gsub(/[[:space:]。．.！!]/, "")
  end

  NORMALIZED_END_PHRASES = END_PHRASES.map { |p| normalize(p) }.freeze
  NORMALIZED_RESUME_PHRASE = normalize(RESUME_PHRASE)

  # now: 取り込み時刻（現在時刻）。末尾の区切りを閉じてよいかの判定に使う。
  # previous_end_reason: 直前の（閉じた）区切りの end_reason。途中から計算し直すとき、
  # 最初の区切りの start_reason を決めるのに使う。
  def self.call(messages, now: Time.current, previous_end_reason: nil)
    new(messages, now:, previous_end_reason:).call
  end

  START_REASON_AFTER = { "gap" => "gap", "end_phrase" => "after_end", "implicit" => "resume_phrase" }.freeze

  def initialize(messages, now: Time.current, previous_end_reason: nil)
    @messages = messages
    @now = now
    @previous_end_reason = previous_end_reason
  end

  def call
    results = []
    current = nil
    closed = false # 終了の合図が出て、後続の assistant の返答を待っている状態

    @messages.each do |message|
      if current.nil?
        current = start(results, [ message ], resume?(message) ? "resume_phrase" : first_start_reason)
      elsif closed
        if message.role == "assistant"
          current.messages << message
          next
        end
        current.end_reason = "end_phrase"
        current = start(results, [ message ], resume?(message) ? "resume_phrase" : "after_end")
        closed = false
      elsif phrase_rule?(message) && resume?(message)
        current.end_reason = "implicit"
        current = start(results, [ message ], "resume_phrase")
      elsif message.occurred_at < PHRASE_RULE_FROM && message.occurred_at - current.messages.last.occurred_at >= GAP
        current.end_reason = "gap"
        current = start(results, [ message ], "gap")
      else
        current.messages << message
      end

      closed = true if phrase_rule?(message) && end_phrase?(message)
    end

    results.last.end_reason = last_end_reason(results.last, closed) if results.any?
    results
  end

  private
    def start(results, messages, reason)
      result = Result.new(messages:, start_reason: reason, continued_from_index: results.empty? ? nil : results.size - 1)
      results << result
      result
    end

    def first_start_reason
      @previous_end_reason ? START_REASON_AFTER.fetch(@previous_end_reason) : "first"
    end

    # 末尾の区切りの終わり方。終了の合図で終わっていても、返答（続き）がまだなら open のままにする。
    # どちらも、最後の発言から GAP 以上たっていれば（now との比較）、返答や合図がなくても閉じる
    # （合図があれば end_phrase、なければ gap）。
    def last_end_reason(result, closed)
      return "end_phrase" if closed && result.messages.last.role != "user"
      return "open" if @now - result.ended_at < GAP
      closed ? "end_phrase" : "gap"
    end

    def phrase_rule?(message)
      message.role == "user" && message.occurred_at >= PHRASE_RULE_FROM
    end

    def end_phrase?(message)
      message.body.to_s.strip.length <= END_PHRASE_MAX_LENGTH &&
        NORMALIZED_END_PHRASES.include?(self.class.normalize(message.body))
    end

    def resume?(message)
      phrase_rule?(message) && self.class.normalize(message.body) == NORMALIZED_RESUME_PHRASE
    end
end
