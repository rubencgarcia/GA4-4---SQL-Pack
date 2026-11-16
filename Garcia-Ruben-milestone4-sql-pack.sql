-- Milestone 4: SQL Pack (Individual)
-- Author: Ruben Garcia
-- Data: bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*

-- Query 1: Preview purchase events for one week
-- Skill: Filtering and scoping (date range + event_name)
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS event_date,
  TIMESTAMP_MICROS(event_timestamp) AS event_time,
  user_pseudo_id,
  event_name,
  ecommerce.transaction_id,
  ecommerce.purchase_revenue AS purchase_revenue_usd,
  device.category AS device_category,
  geo.country AS country
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201207'  -- only scan 7 daily shards
  AND event_name = 'purchase'                          -- only purchase events
ORDER BY event_time
LIMIT 100;

-- Query 2: Event volume for key e-commerce events, one week
-- Skills: Filtering (date range, event_name list) + grouping
SELECT
  event_name,
  COUNT(*) AS event_count,
  COUNT(DISTINCT user_pseudo_id) AS users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201207'
  AND event_name IN (
    'session_start', 'view_item', 'add_to_cart', 'begin_checkout', 'purchase'
  )
GROUP BY event_name
ORDER BY event_count DESC;

-- Query 3: Daily KPI summary for November 2020
-- Skills: GROUP BY with COUNT(*), COUNT(DISTINCT), COUNTIF, SUM
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS date,
  COUNT(*) AS events,
  COUNT(DISTINCT user_pseudo_id) AS users,
  COUNTIF(event_name = 'purchase') AS purchase_events,
  SUM(IF(event_name = 'purchase', ecommerce.purchase_revenue, 0)) AS revenue_usd
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20201130'
GROUP BY date
ORDER BY date;

-- Query 4: Purchasers, orders, revenue, and AOV by acquisition medium
-- Skills: GROUP BY, COUNT(DISTINCT), SUM, SAFE_DIVIDE
SELECT
  traffic_source.medium AS acquisition_medium,
  COUNT(DISTINCT user_pseudo_id) AS purchasers,
  COUNT(DISTINCT ecommerce.transaction_id) AS orders,
  ROUND(SUM(ecommerce.purchase_revenue), 2) AS revenue_usd,
  ROUND(SAFE_DIVIDE(SUM(ecommerce.purchase_revenue),
                    COUNT(DISTINCT ecommerce.transaction_id)), 2) AS avg_order_value_usd
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20201130'
  AND event_name = 'purchase'
GROUP BY acquisition_medium
ORDER BY revenue_usd DESC;

-- Query 5: Top 15 pages by page views
-- Skills: UNNEST(event_params) with key = 'page_location' and string_value
WITH page_views AS (
  SELECT
    user_pseudo_id,
    (SELECT value.string_value
       FROM UNNEST(event_params)
      WHERE key = 'page_location') AS page_location
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201207'
    AND event_name = 'page_view'
)
SELECT
  page_location,
  COUNT(*) AS page_views,
  COUNT(DISTINCT user_pseudo_id) AS unique_users
FROM page_views
GROUP BY page_location
ORDER BY page_views DESC
LIMIT 15;

-- Query 6: Sessions and engagement time by day and device category
-- Skills: UNNEST(event_params) with int_value keys (ga_session_id, engagement_time_msec)
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS date,
  device.category AS device_category,
  COUNT(DISTINCT CONCAT(
    user_pseudo_id, '-',
    CAST((SELECT value.int_value
            FROM UNNEST(event_params)
           WHERE key = 'ga_session_id') AS STRING)
  )) AS sessions,
  ROUND(SUM(
    (SELECT value.int_value
       FROM UNNEST(event_params)
      WHERE key = 'engagement_time_msec')
  ) / 1000 / 60, 1) AS total_engagement_minutes
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20201107'
GROUP BY date, device_category
ORDER BY date, device_category;

-- Query 7: Session-level funnel from view_item to purchase
-- Skills: multiple CTEs, UNNEST, conditional aggregation, combining steps
WITH funnel_events AS (
  -- Step 1: build a base event set with a session key
  SELECT
    CONCAT(
      user_pseudo_id, '-',
      CAST((SELECT value.int_value
              FROM UNNEST(event_params)
             WHERE key = 'ga_session_id') AS STRING)
    ) AS session_key,
    event_name
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20201130'
    AND event_name IN ('view_item', 'add_to_cart', 'begin_checkout', 'purchase')
),
session_steps AS (
  -- Step 2: one row per session, flagging which steps were reached
  SELECT
    session_key,
    MAX(IF(event_name = 'view_item', 1, 0)) AS viewed_item,
    MAX(IF(event_name = 'add_to_cart', 1, 0)) AS added_to_cart,
    MAX(IF(event_name = 'begin_checkout', 1, 0)) AS began_checkout,
    MAX(IF(event_name = 'purchase', 1, 0)) AS purchased
  FROM funnel_events
  GROUP BY session_key
)
-- Step 3: summarize the funnel and calculate step-to-step rates
SELECT
  SUM(viewed_item) AS sessions_view_item,
  SUM(added_to_cart) AS sessions_add_to_cart,
  SUM(began_checkout) AS sessions_begin_checkout,
  SUM(purchased) AS sessions_purchase,
  ROUND(SAFE_DIVIDE(SUM(added_to_cart), SUM(viewed_item)) * 100, 1) AS pct_view_to_cart,
  ROUND(SAFE_DIVIDE(SUM(began_checkout), SUM(added_to_cart)) * 100, 1) AS pct_cart_to_checkout,
  ROUND(SAFE_DIVIDE(SUM(purchased), SUM(began_checkout)) * 100, 1) AS pct_checkout_to_purchase,
  ROUND(SAFE_DIVIDE(SUM(purchased), SUM(viewed_item)) * 100, 2) AS pct_view_to_purchase
FROM session_steps;

-- Query 8: Top 3 pages per day with share of that day's page views
-- Skills: UNNEST, CTEs, JOIN of a derived table back to a daily aggregate
WITH page_views AS (
  -- Event-level extraction: clean page path from page_location
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS date,
    REGEXP_EXTRACT(
      (SELECT value.string_value
         FROM UNNEST(event_params)
        WHERE key = 'page_location'),
      r'https?://[^/]+(/[^?#]*)'
    ) AS page_path
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201123' AND '20201129'  -- Thanksgiving week
    AND event_name = 'page_view'
),
page_daily AS (
  -- Daily views per page
  SELECT date, page_path, COUNT(*) AS page_views
  FROM page_views
  GROUP BY date, page_path
),
daily_totals AS (
  -- Daily aggregate of all page views
  SELECT date, COUNT(*) AS total_page_views
  FROM page_views
  GROUP BY date
)
SELECT
  p.date,
  p.page_path,
  p.page_views,
  d.total_page_views,
  ROUND(SAFE_DIVIDE(p.page_views, d.total_page_views) * 100, 1) AS pct_of_daily_views
FROM page_daily AS p
JOIN daily_totals AS d
  ON p.date = d.date
QUALIFY ROW_NUMBER() OVER (PARTITION BY p.date ORDER BY p.page_views DESC) <= 3
ORDER BY p.date, p.page_views DESC;
