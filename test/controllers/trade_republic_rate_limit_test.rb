require "test_helper"

class TradeRepublicRateLimitIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @previous_enabled = Rack::Attack.enabled
    @previous_store = Rack::Attack.cache.store
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    travel_to Time.utc(2026, 10, 12, 12, 0, 0)
    @item = trade_republic_items(:configured_item)
    @item.update!(pending_login_state: "pending-login")
    @provider = mock
    TradeRepublicItem.any_instance.stubs(:trade_republic_provider).returns(@provider)
  end

  teardown do
    Rack::Attack.enabled = @previous_enabled
    Rack::Attack.cache.store = @previous_store
    travel_back
  end

  test "pending manual completion is throttled without losing state and recovers after the window" do
    @provider.expects(:complete_login).with(pending_login_b64: "pending-login", code: nil).times(10).returns(
      Provider::TradeRepublicClient::Result.new(data: { "status" => "pending" })
    )
    10.times do
      post complete_login_trade_republic_item_path(@item)
      assert_response :redirect
    end

    # Exercise actual Rails routing and the application middleware together.
    post "/trade_republic_items//#{@item.id.upcase}/complete_login.json///"
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
    assert_equal "pending-login", @item.reload.pending_login_state

    travel 1.minute
    @provider.expects(:complete_login).with(pending_login_b64: "pending-login", code: nil).returns(
      Provider::TradeRepublicClient::Result.new(data: { "session_txt" => "authenticated-session" })
    )
    TradeRepublicItem.any_instance.stubs(:sync_later)
    post complete_login_trade_republic_item_path(@item)
    assert_response :redirect
    assert_equal "authenticated-session", @item.reload.session_blob
    assert_nil @item.pending_login_state
    assert @item.good?
  end

  test "accepted UUID spellings share the item budget across source IPs" do
    @provider.expects(:complete_login).with(pending_login_b64: "pending-login", code: nil).times(10).returns(
      Provider::TradeRepublicClient::Result.new(data: { "status" => "pending" })
    )
    variants = [ @item.id, @item.id.upcase, @item.id.delete("-"), @item.id.gsub("-", "%2d"), "%7b#{@item.id}%7d" ]
    10.times do |index|
      post "/trade_republic_items/#{variants[index % variants.length]}/complete_login",
           headers: { "REMOTE_ADDR" => "198.51.100.#{index + 1}" }
      assert_response :redirect
    end

    post "/trade_republic_items/#{@item.id.upcase}/complete_login", headers: { "REMOTE_ADDR" => "203.0.113.99" }
    assert_response :too_many_requests
    assert_equal "pending-login", @item.reload.pending_login_state
  end

  test "automatic push polling does not consume the manual authentication budget" do
    @provider.expects(:complete_login).with(pending_login_b64: "pending-login").times(12).returns(
      Provider::TradeRepublicClient::Result.new(data: { "status" => "pending" })
    )
    12.times do
      post poll_login_trade_republic_item_path(@item), headers: {
        "Accept" => "text/vnd.turbo-stream.html", "X-Requested-With" => "XMLHttpRequest"
      }
      assert_response :no_content
    end

    @provider.expects(:complete_login).with(pending_login_b64: "pending-login", code: nil).times(10).returns(
      Provider::TradeRepublicClient::Result.new(data: { "status" => "pending" })
    )
    10.times do
      post complete_login_trade_republic_item_path(@item)
      assert_response :redirect
    end
    post complete_login_trade_republic_item_path(@item)
    assert_response :too_many_requests
    assert_equal "pending-login", @item.reload.pending_login_state
  end
end
