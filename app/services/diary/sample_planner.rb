module Diary
  # 生成の順序を決める。DBには触れない純粋なモジュール。
  #
  # 最初の塊（first_block）は、次の3つを合わせたもの。残りは、古い順（segment_date、id）。
  # 1. 追加（largest）：入力が最大級の座 LARGEST 座（入力のトークン見積もりが大きい順）。
  # 2. 追加（a_line_picks）：「A:」行を含む座から、無作為に A_LINE_PICKS 座（seed 固定）。1の座は除く。
  # 3. 標本（sample）：1・2を除いた座から、時期 × 型 × 入力の大きさで層別にした、無作為の SAMPLE_SIZE 座（seed 固定）。
  # 追加の座も、標本の座も、全座の一部として扱う（捨てない）。時間の見込みの見直しには、標本（3）を使う
  # （最大級の座は、わざと偏らせているため）。
  #
  # 層 = （時期の区分, 型, 入力の大きさの区分）。時期は、座を日付の順に並べて、座の数が等しくなる PERIODS 区分に、
  # 入力の大きさは、トークン見積もりの順に並べて、座の数が等しくなる SIZE_BUCKETS 区分（3分位）に分ける。
  # 標本の数は、層の大きさに比例して割り振る（最大剰余法）。小さな層も、標本の数が足りる限り、1座は含める。
  module SamplePlanner
    SAMPLE_SIZE = 100
    LARGEST = 5
    A_LINE_PICKS = 10
    SEED = 20_261_102
    PERIODS = 4
    SIZE_BUCKETS = 3

    # input_tokens: 座の入力（全塊）のトークン見積もり。a_lines: 「A:」行を含む発言があるか。
    Descriptor = Struct.new(:id, :segment_date, :input_tokens, :type, :a_lines, keyword_init: true)
    Plan = Struct.new(:order, :first_block, :sample, :largest, :a_line_picks, :strata, keyword_init: true) # strata: { 層 => [標本の数, 層の大きさ] }

    class << self
      def call(descriptors, sample_size: SAMPLE_SIZE, largest: LARGEST, a_line_picks: A_LINE_PICKS, seed: SEED, periods: PERIODS, size_buckets: SIZE_BUCKETS)
        sorted = descriptors.sort_by { |d| [ d.segment_date, d.id ] }
        rng = Random.new(seed)

        largest_ids = descriptors.sort_by { |d| [ -d.input_tokens, d.id ] }.first(largest).map(&:id)
        a_pool = sorted.select { |d| d.a_lines && !largest_ids.include?(d.id) }.map(&:id)
        a_line_ids = a_pool.sample(a_line_picks, random: rng)
        extras = largest_ids + a_line_ids

        pool = sorted.reject { |d| extras.include?(d.id) }
        sample_size = [ sample_size, pool.size ].min
        strata = stratify(pool, periods, size_buckets)
        allocation = allocate(strata, sample_size, pool.size)
        chosen = strata.keys.sort.flat_map { |key| strata[key].map(&:id).sort.sample(allocation.fetch(key), random: rng) }

        in_first = (chosen + extras).to_set
        first_block = sorted.select { |d| in_first.include?(d.id) }.map(&:id)
        rest = sorted.reject { |d| in_first.include?(d.id) }.map(&:id)
        Plan.new(order: first_block + rest, first_block:, sample: sorted.select { |d| chosen.include?(d.id) }.map(&:id),
                 largest: largest_ids, a_line_picks: a_line_ids,
                 strata: strata.keys.sort.to_h { |k| [ k, [ allocation.fetch(k), strata[k].size ] ] })
      end

      private

      # 時期と入力の大きさは、それぞれ、プール内の順位で、座の数が等しくなるように区分する。
      def stratify(pool, periods, size_buckets)
        period_of = bucket_by(pool.sort_by { |d| [ d.segment_date, d.id ] }, periods)
        size_of = bucket_by(pool.sort_by { |d| [ d.input_tokens, d.id ] }, size_buckets)
        pool.group_by { |d| [ period_of.fetch(d.id), d.type.to_s, size_of.fetch(d.id) ] }
      end

      def bucket_by(ordered, buckets)
        ordered.each_with_index.to_h { |d, rank| [ d.id, [ rank * buckets / ordered.size, buckets - 1 ].min ] }
      end

      def allocate(strata, sample_size, total)
        sizes = strata.transform_values(&:size)
        return sizes if sample_size >= total

        quota = sizes.transform_values { |size| sample_size * size.to_f / total }
        allocation = quota.transform_values(&:floor)
        allocation.each_key { |k| allocation[k] = 1 if allocation[k].zero? } if sample_size >= strata.size
        while allocation.values.sum < sample_size
          key = allocation.keys.select { |k| allocation[k] < sizes[k] }.max_by { |k| [ quota[k] - allocation[k], sizes[k], k.to_s ] }
          allocation[key] += 1
        end
        while allocation.values.sum > sample_size
          key = allocation.keys.select { |k| allocation[k] > 1 }.max_by { |k| [ allocation[k] - quota[k], allocation[k], k.to_s ] }
          allocation[key] -= 1
        end
        allocation
      end
    end
  end
end
