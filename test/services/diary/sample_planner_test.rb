require "test_helper"

# ダミーの座だけを使う。DBには触れない。
class Diary::SamplePlannerTest < ActiveSupport::TestCase
  Planner = Diary::SamplePlanner

  # 400座。日付は1日1座ずつ。型（3ごと）、入力の大きさ（i×37 を997で割った余り。日付とは独立）、
  # 「A:」行（11ごと）を、互いに素な周期で散らす。
  def descriptors(count = 400)
    Array.new(count) do |i|
      Planner::Descriptor.new(id: i + 1, segment_date: Date.new(2026, 1, 1) + i, input_tokens: ((i * 37) % 997) + 10,
                              type: (i % 3).zero? ? :work : :talk, a_lines: (i % 11).zero?)
    end
  end

  def plan(count = 400, **options) = Planner.call(descriptors(count), **options)

  test "最初の塊は、標本100座＋最大級5座＋A:行10座。重ならず、全座がちょうど1回ずつ並ぶ" do
    result = plan
    assert_equal 100, result.sample.size
    assert_equal 5, result.largest.size
    assert_equal 10, result.a_line_picks.size
    assert_equal 115, result.first_block.size
    assert_equal 115, (result.sample + result.largest + result.a_line_picks).uniq.size
    assert_equal result.first_block, result.order.first(115)
    assert_equal descriptors.map(&:id).sort, result.order.sort
    rest = result.order.drop(115)
    assert_equal rest.sort, rest, "残りは、日付（と id）の昇順"
  end

  test "最初の塊は、日付の順に並べる" do
    result = plan
    assert_equal result.first_block.sort, result.first_block
  end

  test "入力が最大級の座を、大きい順に5座選ぶ" do
    expected = descriptors.sort_by { |d| [ -d.input_tokens, d.id ] }.first(5).map(&:id)
    assert_equal expected, plan.largest
  end

  test "A:行の座は、「A:」行を含む座だけから選ぶ。最大級の座とは重ならない" do
    result = plan
    a_ids = descriptors.select(&:a_lines).map(&:id)
    assert(result.a_line_picks.all? { |id| a_ids.include?(id) })
    assert_empty(result.a_line_picks & result.largest)
  end

  test "A:行の座が足りなければ、ある分だけ" do
    few = descriptors.each_with_index.map { |d, i| d.tap { |x| x.a_lines = i < 3 } }
    result = Planner.call(few)
    assert_equal 3, result.a_line_picks.size
  end

  test "標本は、最大級の座とA:行の座を除いた座から選ぶ（標本は追加と重ならない）" do
    result = plan
    assert_empty(result.sample & result.largest)
    assert_empty(result.sample & result.a_line_picks)
  end

  test "seed を固定すれば同じ。seed を変えれば変わる" do
    assert_equal plan.order, plan.order
    assert_not_equal plan.sample, plan(seed: 1).sample
    assert_not_equal plan.a_line_picks, plan(seed: 1).a_line_picks
  end

  test "入力の順序に依存しない" do
    shuffled = descriptors.shuffle(random: Random.new(3))
    assert_equal plan.order, Planner.call(shuffled).order
  end

  test "層（時期4 × 型2 × 入力の大きさ3）のすべてに、標本が入る。合計はちょうど標本の数" do
    result = plan
    assert_equal 4 * 2 * 3, result.strata.size
    assert(result.strata.values.all? { |picked, size| picked >= 1 && picked <= size })
    assert_equal 100, result.strata.values.sum(&:first)
    assert_equal [ 0, 1, 2 ], result.strata.keys.map(&:last).uniq.sort
  end

  test "標本の数は、層の大きさに、おおよそ比例する" do
    result = plan
    pool = result.strata.values.sum(&:last)
    result.strata.each_value { |picked, size| assert_in_delta 100.0 * size / pool, picked, 2.0 }
  end

  test "入力の大きさの区分は、座の数が等しくなる3分位" do
    result = plan
    sizes = result.strata.group_by { |key, _| key.last }.transform_values { |entries| entries.sum { |_, (_, size)| size } }
    assert_equal 3, sizes.size
    assert_operator sizes.values.max - sizes.values.min, :<=, 3
  end

  test "標本は、全期間と、入力の大きい座にも小さい座にも散らばる" do
    result = plan
    by_id = descriptors.to_h { |d| [ d.id, d ] }
    quarters = result.sample.map { |id| (by_id[id].segment_date - Date.new(2026, 1, 1)).to_i * 4 / 400 }.uniq.sort
    assert_equal [ 0, 1, 2, 3 ], quarters
    tokens = result.sample.map { |id| by_id[id].input_tokens }
    assert_operator tokens.min, :<, 200
    assert_operator tokens.max, :>, 800
  end

  test "work の座も talk の座も、標本に入る" do
    result = plan
    by_id = descriptors.to_h { |d| [ d.id, d ] }
    assert(result.sample.any? { |id| by_id[id].type == :work })
    assert(result.sample.any? { |id| by_id[id].type == :talk })
  end

  test "座の数が少なければ、標本は残りの全座" do
    result = plan(30)
    assert_equal 30, result.order.size
    assert_equal 30, result.first_block.size
    assert_equal result.sample.size + result.largest.size + result.a_line_picks.size, 30
  end

  test "空の入力でも動く" do
    result = Planner.call([])
    assert_equal [], result.order
    assert_equal [], result.sample
  end

  test "標本の数が層の数より少なくても、割り振りの合計は標本の数に合う" do
    result = plan(sample_size: 10)
    assert_equal 10, result.sample.size
    assert_equal 10, result.strata.values.sum(&:first)
  end
end
