require 'jiji/model/agents/agent'

class AccelMaAgent

  include Jiji::Model::Agents::Agent
    def self.description
    <<-STR
Accel MAを使うエージェントです。
      STR
  end

  # UIから設定可能なプロパティの一覧
  def self.property_infos
    [
      Property.new('symbol',  'シンボル', 'USDJPY'),
      Property.new('tf',  'タイムフレーム', 60),
      Property.new('max_bars',  '最大バー数', 20),
      Property.new('k', 'K', 0.5),
      Property.new('period', 'MA期間', 24),
      Property.new('smoothing',  'スムージング', 10),
      Property.new('gannbars',  'Gann期間', 11)
    ]
  end

  def post_create
    # 移動平均の算出クラス
    # 共有ライブラリのクラスを利用。
    @accelma    = AccelMA.new(@k.to_f,@period.to_i,@smoothing.to_i)
    @candles    = Candles.new(@tf.to_i, @max_bars.to_i * @tf.to_i)

    # 移動平均グラフ
    @graph1 = graph_factory.create('Accel MA',:rate, :average, ['#779999'])
    
  end

  # 次のレートを受け取る
  def next_tick(tick)
    tick_value=tick[@symbol.to_sym]
    
    if(@candles.update(tick_value, tick.timestamp) && @candles.candles.length >= 2)
        h = @candles.candles[-2].high
        l = @candles.candles[-2].low
        o = tick_value.bid 
        return if h==l 


        if @accelma.next_data(h,l,o) != nil
             logger.debug "1 %s : %s (%s  %s)" % [tick.timestamp,o,@accelma.main[-1],@accelma.sig[-1]]
            
            # グラフに出力
            @graph1 << [@accelma.main[-1]]
            # ゴールデンクロス/デッドクロスを判定
            do_trade
        end
    end

  end

  def do_trade
    if  @accelma.sig[-1]==1
      # 売り建玉があれば全て決済
      close_exist_positions(:sell)
      if !exist_positions(:buy)
        # 新規に買い
        broker.buy(@symbol.to_sym, 1)
      end
    elsif @accelma.sig[-1]== -1
      # 買い建玉があれば全て決済
      close_exist_positions(:buy)
      if !exist_positions(:sell)
        # 新規に売り
        broker.sell(@symbol.to_sym, 1)
      end
    end
  end

  def close_exist_positions(sell_or_buy)
    @broker.positions.each do |p|
      p.close if p.sell_or_buy == sell_or_buy
    end
  end
  
  def exist_positions(sell_or_buy)
    @broker.positions.each do |p|
      return true if p.sell_or_buy == sell_or_buy
    end
    return false
  end


  # エージェントの状態を返却
  def state
    {accelma: @accelma.state, candles: @candles.state}
  end

  # 永続化された状態から元の状態を復元する
  def restore_state(state)
    return unless state[:candles]
    @accelma.restore_state(state[:accelma])
    @candles.restore_state(state[:candles])
  end

end

class Candles
  attr_reader :candles
  attr_reader :period
  attr_reader :tf

  def initialize(tf,period)
    @candles     = []
    @tf      = tf
    @period      = period
    @next_update = nil
  end

  def update(tick_value, time)
    time = Candles.normalize_time(time,@tf)
    if @next_update.nil? || time >= @next_update
      new_candle(tick_value, time)
      return true
    else
      @candles.last.update(tick_value, time)
    end
      return false
  end

  def highest
    high = @candles.max_by { |c| c.high }
    high.nil? ? nil : BigDecimal.new(high.high, 10)
  end

  def lowest
    low = @candles.min_by { |c| c.low }
    low.nil? ? nil : BigDecimal.new(low.low, 10)
  end

  def oldest_time
    oldest = @candles.min_by { |c| c.time }
    oldest.nil? ? nil : oldest.time
  end

  def reset
    @candles     = []
    @next_update = nil
  end

  def new_candle(tick_value, time)
    limit = time - @period * 60 * @tf
    @candles = @candles.reject { |c| c.time < limit }
    @candles << Candle.new
    
    @candles.last.update(tick_value, time)

    @next_update = time + (60 * @tf)
  end

  def state
    {
      candles:     @candles.map { |c| c.to_h },
      next_update: @next_update
    }
  end

  def restore_state(state)
    @candles = state[:candles].map { |s| Candle.from_h(s) }
    @next_update = state[:next_update]
  end

  def self.normalize_time(time,tf)
    Time.at((time.to_i / (60 * tf)).floor * 60 * tf)
  end

end

class Candle

  attr_reader :high, :low, :time, :price

  def initialize(high = nil, low = nil, time = nil, price = nil)
    @high = high
    @low  = low
    @time = time
    @price = price
  end

  def update(tick_value, time)
    @price = extract_price(tick_value)
    @high = @price if @high.nil? || @high < @price
    @low  = @price if @low.nil?  || @low > @price
    @time = time  if @time.nil?
  end

  def to_h
    { high: @high, low: @low, time: @time ,price: @price}
  end

  def self.from_h(hash)
    Candle.new(hash[:high], hash[:low], hash[:time], hash[:price])
  end

  private

  def extract_price(tick_value)
    tick_value.bid
  end
end

class AccelMA
    attr_reader :ma
    attr_reader :main
    attr_reader :sig
    
    include Math
    # コンストラクタ
    # range:: 集計期間
    def initialize(k=0.5,period=20,smoothing=10)
        @threshold=0.03
        @alpha = 0.99
        @index=0
        #---
        @main = []
        @sig = []
        @ma = []
        @mom = []
        @price = []
        @atr = []
        #---
        @k =  [0.001,[1,k].min].max
        @period = [1,period].max
        @smoothing = [1,smoothing].max
        #---
        @accel_period=(@k*15).to_i
        @calc_begin = [2,@accel_period+2,@period+2].max
        @correct_begin=@calc_begin+@period+@smoothing+4

        #--- accel filter
        @accel=[]
        i=1
        while i <= @accel_period
           @accel.push @k ** log(i)
           i+=1
        end

        #--- smoothing filter
        temp = exp((-sqrt(2)*PI)/@smoothing)
        @coef2 = 2 * temp * cos((sqrt(2)*PI)/@smoothing)
        @coef3 = -temp * temp
        @coef1 = 1 - @coef2 - @coef3
    end
    
    def state
    {
        main: @main, 
        sig: @sig,
        ma: @ma, 
        mom: @mom,
        price: @price,
        atr: @atr,
        threshold: @threshold,
        alpha: @alpha,
        index: @index,
        k: @k,
        period: @period,
        smoothing: @smoothing,
        accel_period: @accel_period,
        calc_begin: @calc_begin,
        correct_begin: @correct_begin,
        accel: @accel,
        coef1: @coef1,
        coef2: @coef2,
        coef3: @coef3
    }
    end

    def restore_state(state)
        @main = state[:main]
        @sig = state[:sig]
        @ma = state[:ma]
        @mom = state[:mom]
        @price = state[:price]
        @atr = state[:atr]
        @threshold= state[:threshold]
        @alpha= state[:alpha]
        @index= state[:index]
        @k= state[:k]
        @period= state[:period]
        @smoothing= state[:smoothing]
        @accel_period= state[:accel_period]
        @calc_begin= state[:calc_begin]
        @correct_begin= state[:correct_begin]
        @accel= state[:accel]
        @coef1= state[:coef1]
        @coef2= state[:coef2]
        @coef3= state[:coef3]
    end

    # 次のデータを受け取って指標を返します。
    # data:: 次のデータ
    # 戻り値:: 指標。十分なデータが蓄積されていない場合nil
    def next_data(hi,lo,op)
        @index+=1

        @main.shift if @main.length >@calc_begin
        @main.push op

        @sig.shift if @sig.length >@calc_begin
        @sig.push 0

        @price.shift if @price.length >@calc_begin
        @price.push op

        @ma.shift if @ma.length >@calc_begin
        @ma.push op


        @atr.shift if @atr.length >@calc_begin
        @atr.push [hi,op].max-[lo,op].min

        #---
        return nil if (@index==1)
        @atr[-1] = (1-@alpha) * @atr[-1] + @alpha * @atr[-2]
        
        @mom.shift if @mom.length >@calc_begin
        @mom.push (@price[-1]-@price[-2])
        return nil if(@index <= @calc_begin)

        #---
        dsum=0.0000000000001
        volat=0.0000000000001
        dmax=0
        dmin=0
        sz=@mom.length-1
        j=0
        while j<@accel_period
            dsum += @mom[sz-j] * @accel[j]
            dmax = dsum if (dsum>dmax)
            dmin = dsum if (dsum<dmin)
            j+=1
        end
        
        j=0
        while j<@period
            volat += @mom[sz-j].abs
            j+=1
        end
        
        range = [0.0000000000001,dmax-dmin].max

        @ma[-1] = (range / volat) * (op - @ma[-2]) + @ma[-2]
        @main[-1] = @coef1 * @ma[-1] + @coef2 * @main[-2] + @coef3 * @main[-3]        
        #---
        return nil if(@index <= @calc_begin+3)
        thr= @threshold * @atr[-1]
        prev = (@main[-4] + @main[-3] + @main[-2]) / 3
        slope = (@main[-1]-prev)*0.5

        sig=0
        if (slope.abs < thr) 
            sig = 0
        elsif(slope > 0) 
            sig = 1
        elsif(slope < 0) 
            sig =-1
        else
            sig =@sig[-2]
        end
        @sig[-1] = sig
        return nil if @index <= @correct_begin
        1
        
    end
end