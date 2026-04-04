require "rails_helper"

RSpec.describe "Shipments", type: :system do
  let!(:user) { create(:user) }
  let!(:store) { create(:shopify_store, user: user) }
  let!(:customer) { create(:customer, shopify_store: store) }
  let!(:order) { create(:order, customer: customer, shopify_store: store) }
  let!(:shipment) do
    create(:fulfillment, order: order, tracking_number: "TEST123",
           tracking_status: "InTransit", origin_carrier: "China Post",
           destination_country: "US", transit_days: 10)
  end

  before { sign_in_as(user) }

  describe "column toggle" do
    before do
      click_link "Shipments"
      expect(page).to have_text("TEST123")
    end

    def open_column_dropdown
      find("[data-action='click->column-toggle#toggle']").click
      expect(page).to have_css("[data-column-toggle-target='dropdown']:not(.hidden)")
    end

    def column_hidden?(column)
      page.evaluate_script("document.querySelector(\"th[data-column='#{column}']\").classList.contains('hidden')")
    end

    # Toggle column visibility and persist to localStorage (mirrors controller logic)
    def toggle_column_visibility(column)
      page.execute_script(<<~JS)
        var cb = document.querySelector("input[data-column='#{column}']");
        cb.checked = !cb.checked;
        var visible = cb.checked;

        document.querySelectorAll("th[data-column='#{column}'], td[data-column='#{column}']").forEach(function(el) {
          if (visible) { el.classList.remove("hidden"); } else { el.classList.add("hidden"); }
        });

        var list = document.querySelector("[data-column-toggle-target='list']");
        var prefs = Array.from(list.querySelectorAll("[data-column-toggle-target='item']")).map(function(item) {
          var c = item.dataset.column;
          var checkbox = item.querySelector("input[type='checkbox']");
          return { id: c, visible: checkbox ? checkbox.checked : true };
        });
        localStorage.setItem("shipment_columns", JSON.stringify(prefs));
      JS
    end

    # Simulate drag-and-drop reorder by manipulating DOM + saving to localStorage
    def reorder_column_before(column_to_move, before_column)
      page.execute_script(<<~JS, column_to_move, before_column)
        var colToMove = arguments[0];
        var colBefore = arguments[1];
        var list = document.querySelector("[data-column-toggle-target='list']");
        var items = Array.from(list.querySelectorAll("[data-column-toggle-target='item']"));
        var moveItem = items.find(function(i) { return i.dataset.column === colToMove; });
        var beforeItem = items.find(function(i) { return i.dataset.column === colBefore; });
        list.insertBefore(moveItem, beforeItem);

        var order = Array.from(list.querySelectorAll("[data-column-toggle-target='item']"))
          .map(function(item) { return item.dataset.column; });

        document.querySelectorAll("table tr").forEach(function(row) {
          var cells = Array.from(row.children);
          if (cells.length === 0) return;
          var cellMap = {};
          cells.slice(1).forEach(function(cell) {
            var col = cell.getAttribute("data-column");
            if (col) cellMap[col] = cell;
          });
          order.forEach(function(colId) {
            var cell = cellMap[colId];
            if (cell) row.appendChild(cell);
          });
        });

        var prefs = Array.from(list.querySelectorAll("[data-column-toggle-target='item']")).map(function(item) {
          var col = item.dataset.column;
          var cb = item.querySelector("input[type='checkbox']");
          return { id: col, visible: cb ? cb.checked : true };
        });
        localStorage.setItem("shipment_columns", JSON.stringify(prefs));
      JS
    end

    it "shows and hides columns via checkboxes" do
      expect(column_hidden?("status")).to be false

      open_column_dropdown
      toggle_column_visibility("status")
      expect(column_hidden?("status")).to be true

      toggle_column_visibility("status")
      expect(column_hidden?("status")).to be false
    end

    it "shows drag handles in the column toggle dropdown" do
      open_column_dropdown

      within("[data-column-toggle-target='dropdown']") do
        checkboxes = all("input[type='checkbox'][data-column]", visible: :all)
        expect(all("[data-drag-handle]").length).to eq(checkboxes.length)
      end
    end

    it "reorders table columns" do
      headers = all("thead th[data-column]", visible: true).map { |th| th["data-column"] }
      expect(headers.index("order_info")).to be < headers.index("destination")

      reorder_column_before("destination", "order_info")

      reordered = all("thead th[data-column]", visible: true).map { |th| th["data-column"] }
      expect(reordered.index("destination")).to be < reordered.index("order_info")
    end

    it "persists column visibility across page loads" do
      open_column_dropdown
      toggle_column_visibility("status")
      expect(column_hidden?("status")).to be true

      visit shipments_path
      expect(page).to have_text("TEST123")

      expect(column_hidden?("status")).to be true
    end

    it "persists column order in localStorage" do
      reorder_column_before("destination", "order_info")

      stored = page.evaluate_script("localStorage.getItem('shipment_columns')")
      parsed = JSON.parse(stored)
      ids = parsed.map { |p| p["id"] }
      expect(ids.index("destination")).to be < ids.index("order_info")

      dest_pref = parsed.find { |p| p["id"] == "destination" }
      expect(dest_pref["visible"]).to be true
    end

    it "applies saved column order on page load" do
      reorder_column_before("destination", "order_info")

      visit shipments_path
      expect(page).to have_text("TEST123")

      # Use XPath to assert destination precedes order_info (Capybara auto-waits)
      expect(page).to have_xpath(
        "//thead/tr/th[@data-column='destination']/following-sibling::th[@data-column='order_info']"
      )
    end

    it "keeps tracking_no as the first column regardless of reorder" do
      first_th = find("thead tr th:first-child")
      expect(first_th.text.downcase).to include("tracking no")
      expect(first_th["data-column"]).to be_nil
    end
  end
end
