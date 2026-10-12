# frozen_string_literal: true

require "test_helper"

class TradeRepublicRateLimitTest < ActiveSupport::TestCase
  setup do
    @previous_enabled = Rack::Attack.enabled
    @previous_store = Rack::Attack.cache.store
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    @app = Rack::Attack.new(->(_env) { [ 204, {}, [] ] })
    travel_to Time.utc(2026, 10, 12, 12, 0, 0)
  end

  teardown do
    Rack::Attack.enabled = @previous_enabled
    Rack::Attack.cache.store = @previous_store
    travel_back
  end

  test "authentication endpoints reject the eleventh attempt with retry instructions" do
    [
      [ "POST", "/trade_republic_items" ],
      [ "PATCH", "/trade_republic_items/item-1" ],
      [ "PUT", "/trade_republic_items/item-1" ],
      [ "POST", "/trade_republic_items/item-1/initiate_login" ],
      [ "POST", "/trade_republic_items/item-1/complete_login" ],
      [ "POST", "/trade_republic_items/item-1/initiate_qr_login" ]
    ].each do |method, path|
      [ "", ".json", ".rate-limit" ].each do |format|
        Rack::Attack.cache.store.clear
        10.times { assert_equal 204, request("#{path}#{format}", method: method).first }

        status, headers, body = request("#{path}#{format}", method: method)
        assert_equal 429, status, "#{method} #{path}#{format} must be throttled"
        assert_equal "60", headers["Retry-After"]
        assert_equal "Rate limit exceeded. Try again later.", JSON.parse(body.join).fetch("error")
      end
    end
  end

  test "authentication actions and item ids share the ip budget" do
    5.times { assert_equal 204, request("/trade_republic_items").first }
    5.times { assert_equal 204, request("/trade_republic_items/item-1/initiate_login").first }

    assert_equal 429, request("/trade_republic_items/item-2/complete_login").first
    assert_equal 204, request("/trade_republic_items/item-2/complete_login", ip: "203.0.113.6").first
  end

  test "rotating ips and authentication actions cannot bypass the item budget" do
    10.times do |index|
      path = index.even? ? "/trade_republic_items/item-1/initiate_login" : "/trade_republic_items/item-1/complete_login.json"
      assert_equal 204, request(path, ip: "203.0.113.#{index + 1}").first
    end

    assert_equal 429, request("/trade_republic_items/item-1", method: "PATCH", ip: "203.0.113.99").first
    assert_equal 204, request("/trade_republic_items/item-2/initiate_login", ip: "203.0.113.99").first
  end

  test "equivalent uuid spellings cannot bypass the item budget" do
    item_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    10.times do |index|
      assert_equal 204, request("/trade_republic_items/#{item_id}/complete_login", ip: "203.0.113.#{index + 1}").first
    end

    [ item_id.upcase, item_id.delete("-"), item_id.gsub("-", "%2D"), "%7B#{item_id}%7D" ].each do |variant|
      assert_equal 429, request("/trade_republic_items/#{variant}/complete_login", ip: "203.0.113.99").first
    end
  end

  test "authentication budgets reset after one minute" do
    10.times { request("/trade_republic_items/item-1/complete_login") }
    assert_equal 429, request("/trade_republic_items/item-1/complete_login").first

    travel 1.minute

    assert_equal 204, request("/trade_republic_items/item-1/complete_login").first
  end

  test "malformed utf8 item ids do not crash before Rails can reject them" do
    [ "%FF", "%C0%AF", "%E2%82" ].each do |item_id|
      [
        [ "PATCH", "/trade_republic_items/#{item_id}" ],
        [ "PUT", "/trade_republic_items/#{item_id}" ],
        [ "POST", "/trade_republic_items/#{item_id}/initiate_login" ],
        [ "POST", "/trade_republic_items/#{item_id}/complete_login" ],
        [ "POST", "/trade_republic_items/#{item_id}/initiate_qr_login" ]
      ].each do |method, path|
        assert_nothing_raised do
          assert_equal 204, request(path, method: method).first
        end
      end
    end
  end

  test "polling and non authentication requests do not consume the login budget" do
    [
      [ "GET", "/trade_republic_items/item-1" ],
      [ "DELETE", "/trade_republic_items/item-1" ],
      [ "GET", "/trade_republic_items/item-1/initiate_login" ],
      [ "POST", "/trade_republic_items/item-1/poll_login" ],
      [ "POST", "/trade_republic_items/item-1/poll_qr_login" ],
      [ "POST", "/trade_republic_items/item-1/cancel_qr_login" ],
      [ "POST", "/trade_republic_items/item-1/sync" ],
      [ "POST", "/trade_republic_items/item-1/complete_account_setup" ],
      [ "POST", "/trade_republic_items/item-1/complete_login_other" ],
      [ "POST", "/trade_republic_items_other" ]
    ].each do |method, path|
      11.times { assert_equal 204, request(path, method: method).first, "#{method} #{path}" }
    end

    10.times { assert_equal 204, request("/trade_republic_items/item-1/complete_login").first }
    assert_equal 429, request("/trade_republic_items/item-1/complete_login").first
  end

  private

    def request(path, method: "POST", ip: "203.0.113.5")
      @app.call(Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ip))
    end
end
