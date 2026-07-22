# 华磊 (sz56t / Raydo) 货代 API 参考

> 来源：`http://doc.sz56t.com:8090/doc-wiki#/page/share/view?space=23bdefb8e45248fcb5e4a98f54bb8416&pageId=232`（「华磊系统API」）。
> 该 wiki 是 zyplayer-doc-wiki（Vue SPA），页面内容经开放接口取得：
> `POST /zyplayer-doc-wiki/open-api/page/detail`，form 参数 `pageId=232&space=<uuid>`，内容在 `data.pageContent.content`。
> 原文完整存于 `raydo-huali-api-raw.txt`。**测试环境地址仅供参考，正式环境 URL 需向货代索取，配置在 `LogisticsAccount.url1_base` / `url2_base`。**

## 两个基地址
- **URL1 = 创建订单域**（`LogisticsAccount#url1_base`）——认证、渠道列表、**下单**、**获取跟踪号** 全在这里。
- **URL2 = 打印标签域**（`LogisticsAccount#url2_base`）——面单/标签（2C 之后的阶段用）。

> ⚠️ 纠正早期假设：**下单接口在 URL1，不是 URL2**。URL2 只管打印标签。

## 已实现（`FulfillmentService::Raydo`）
- `GET URL1/selectAuth.htm?username=&password=` → `{customer_id, customer_userid, ack}`；`ack=="true"` 认证成功。`customer_id` / `customer_userid` 下单必填。
- `GET URL1/getProductList.htm` → `[{product_id, product_shortname}]`；`product_id` 存于 `LogisticsChannel#product_id`。

## 2C 核心：创建订单
`POST URL1/createOrderApi.htm?param=<JSON>`（param 为 URL 编码后的 JSON 字符串；GBK 响应，参照现有 `parse_response`）。

**请求关键字段**（← 映射来源）：
- 收件人/地址 ← `Package#shipping_address_snapshot`：
  `consignee_name`(必填) `consignee_address`(街道,必填) `consignee_telephone`(必填) `country`(二字码,必填)
  `consignee_state` `consignee_city` `consignee_postcode`(有邮编国家必填) `consignee_mobile` `consignee_email` `consignee_companyname` `consignee_suburb`。
- `product_id`(运输方式,必填) ← `LogisticsChannel#product_id`。
- `order_customerinvoicecode`(原单号,必填) ← 我方参考号（建议用 `Package#package_code`）。
- `weight`(总重,选填) `order_piece`(件数,小包默认1) `cargo_type`(P包裹/D文件/B PAK袋)。
- `customer_id` / `customer_userid`(必填) ← 认证结果。
- `orderInvoiceParam[]`（逐项报关，对每个 **非全退** `PackageItem`）：
  `invoice_amount`(申报总价值,必填) `invoice_pcs`(件数,必填) `invoice_title`(英文品名,必填) `sku`(中文品名)
  `invoice_weight`(单件重) `hs_code` `import_hs_code` `origin_country` 等。
  ← 映射自 `PackageItem` 的 customs 字段（`customs_name_en`→invoice_title、`customs_name_zh`→sku、`declared_value_usd`→invoice_amount、`customs_weight_grams`→invoice_weight、`hs_code`/`import_hs_code`、`quantity-refunded_quantity`→invoice_pcs）。
- `orderVolumeParam[]`（选填体积）。

**响应关键字段**：
```
{
  "ack": "true|false",
  "order_id": "…",             // 必存，打印标签要用
  "tracking_number": "…",       // 跟踪号（若当场分配）
  "childList": [{"child_number":"子单号"}],
  "is_delay": "Y=需要延迟获取单号",
  "product_tracknoapitype": "值为3时需调用『获取跟踪号』接口更新单号",
  "message": "失败原因(需 urldecode)",
  "is_remote": "N/Y/A/B/C 偏远",
  "is_residential": "Y=住宅"
}
```

**同步/异步（混合）判定 → 决定 2C 流程**：
- `ack != "true"` → **失败**：`message` urldecode 存起来，`application_status=failed`，留在 `applying_tracking` 供重试。
- `ack == "true"` 且 `tracking_number` 已有且 `is_delay != "Y"` 且 `product_tracknoapitype != "3"` → **当场取号成功**：存 `order_id` + 运单号，`application_status=succeeded`，`to_label` → `pending_label`。
- `ack == "true"` 但 `is_delay=="Y"` 或 `product_tracknoapitype=="3"` 或 `tracking_number` 为空 → **延迟取号**：存 `order_id`，`application_status=pending`，留在 `applying_tracking`，由后台轮询下方接口。

## 延迟取号轮询
`GET URL1/getOrderTrackingNumber.htm?order_id=<order_id>`（或 `?documentCode=<原单号>`）→
```
{
  "status": "200",                    // 200=成功
  "msg": "获取成功",
  "childno": ["子单号…"],
  "order_serveinvoicecode": "转单号（尾程单号）= 最终运单号",
  "order_referencecode": "参考号",
  "express_type": "快递类型",
  "product_tracknoapitype": ""
}
```
- `status==200` 且 `order_serveinvoicecode` 非空 → 取号成功 → `succeeded` → `pending_label`。
- 否则仍未出号 → 保持 `pending`，稍后再轮询。
- 批量版：`getOrderTrackingNumberBatch.htm?order_id=<逗号分隔>`。

## 后续阶段会用到（非 2C）
- **批量下单**：`createOrderBatchApi.htm?param=[{…},{…}]`。
- **打印标签**（URL2 域）：`postOrderApi.htm` / `selectLabelType.htm`。
- 其他：`updateOrderWeightByApi.htm`、`modifyInsurance.htm`、`selectTrack.htm`。

## 出货（shipped）阶段（延后，非 2C）
拿到运单号后**不立即**注册 17Track / 回写 Shopify——按用户决策，等包裹「已交运(shipped)」时才做（出货前运单号可能被打回）。
