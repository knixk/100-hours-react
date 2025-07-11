/*

Metrics for revenue amount and engagement (deliveries, count total opens, count unique opens, unique open rate, count unique clicks, click rate) across channels

Notes:
    Revenue & transactions are attributed to multiple channels.
    A value will be "Null" and display as empty if not applicable for that channel.

*/

-- Select distinct purchase events for each user within the past 30 days
WITH user_purchases AS (
    SELECT DISTINCT
        concat(user_id, '-', time) AS purchase_event_id,
        user_id,
        time,
        price
    FROM USERS_BEHAVIORS_PURCHASE_SHARED
    WHERE date_trunc('day', to_timestamp_ntz(time)) >= dateadd('day', -30, date_trunc('day', CURRENT_DATE()))
),

-- Select distinct email delivery events for each user within the past 30 days
delivered_emails AS (
    SELECT DISTINCT
        id AS email_delivery_id,
        time AS email_delivery_time,
        user_id
    FROM USERS_MESSAGES_EMAIL_DELIVERY_SHARED
    WHERE date_trunc('day', to_timestamp_ntz(time)) >= dateadd('day', -30, date_trunc('day', CURRENT_DATE()))
),

-- Select distinct email open events for each user within the past 30 days
opened_emails AS (
    SELECT DISTINCT
        id AS email_open_id,
        time AS email_open_time,
        user_id
    FROM USERS_MESSAGES_EMAIL_OPEN_SHARED
    WHERE date_trunc('day', to_timestamp_ntz(time)) >= dateadd('day', -30, date_trunc('day', CURRENT_DATE()))
),

-- Select distinct email click events for each user within the past 30 days
clicked_emails AS (
    SELECT DISTINCT
        id AS email_click_id,
        time AS email_click_time,
        user_id
    FROM USERS_MESSAGES_EMAIL_CLICK_SHARED
    WHERE date_trunc('day', to_timestamp_ntz(time)) >= dateadd('day', -30, date_trunc('day', CURRENT_DATE()))
),

-- Select distinct users who unsubscribed from emails within the past 30 days
unsubscribed_emails AS (
    SELECT DISTINCT
        user_id
    FROM USERS_MESSAGES_EMAIL_UNSUBSCRIBE_SHARED
    WHERE date_trunc('day', to_timestamp_ntz(time)) >= dateadd('day', -30, date_trunc('day', CURRENT_DATE()))
),

-- Select distinct push notification delivery events for each user within the past 30 days
delivered_pushs AS (
    SELECT DISTINCT
        id AS push_open_id,
        time AS push_open_time,
        user_id
    FROM USERS_MESSAGES_PUSHNOTIFICATION_SEND_SHARED
    WHERE date_trunc('day', to_timestamp_ntz(time)) >= dateadd('day', -30, date_trunc('day', CURRENT_DATE()))
),

-- Select distinct push notification open events for each user within the past 30 days
opened_pushs AS (
    SELECT DISTINCT
        id AS push_open_id,
        time AS push_open_time,
        user_id
    FROM USERS_MESSAGES_PUSHNOTIFICATION_OPEN_SHARED
    WHERE date_trunc('day', to_timestamp_ntz(time)) >= dateadd('day', -30, date_trunc('day', CURRENT_DATE()))
),

-- Select distinct push notification influenced open events for each user within the past 30 days
influenced_pushs AS (
    SELECT DISTINCT
        id AS push_open_id,
        time AS push_open_time,
        user_id
    FROM USERS_MESSAGES_PUSHNOTIFICATION_INFLUENCEDOPEN_SHARED
    WHERE date_trunc('day', to_timestamp_ntz(time)) >= dateadd('day', -30, date_trunc('day', CURRENT_DATE()))
),

-- Select distinct iam click events for each user within the past 30 days
clicked_iam AS (
    SELECT DISTINCT
        id as iam_click_id,
        time as iam_click_time,
        user_id
    FROM USERS_MESSAGES_INAPPMESSAGE_CLICK_SHARED
    WHERE date_trunc('day', to_timestamp_ntz(time)) >= dateadd('day', -30, date_trunc('day', CURRENT_DATE()))
),

-- Combine opened and influenced pushes to treat them the same.
push_merge AS (
    SELECT
        push_open_id,
        user_id,
        push_open_time
    FROM influenced_pushs
    UNION
    SELECT
        push_open_id,
        user_id,
        push_open_time
    FROM opened_pushs
),

-- Generate a table with one row per user interaction event we care about, joined with purchase event data.
-- This can lead to multiple rows with the same purchase_event_id and purchase event data, which will be handled later in the process.
purchases_with_user_interaction_events AS (
    SELECT purchase_event_id,
        user_purchases.user_id,
        user_purchases.time as purchase_time,
        user_purchases.price,
        email_delivery_time,
        push_open_time,
        iam_click_time
    FROM user_purchases
    LEFT JOIN delivered_emails ON user_purchases.user_id = delivered_emails.user_id
    LEFT JOIN push_merge ON user_purchases.user_id = push_merge.user_id
    LEFT JOIN clicked_iam ON user_purchases.user_id = clicked_iam.user_id
),

-- Narrow down the above results to only those user interaction events that occurred after contact.
purchases_within_time_frame AS (
    SELECT purchase_event_id,
        user_id,
        CASE
            WHEN (email_delivery_time IS NOT NULL AND email_delivery_time <= purchase_time) THEN price
            ELSE 0
        END as email_added_revenue,
        CASE
            WHEN (push_open_time IS NOT NULL AND push_open_time <= purchase_time) THEN price
            ELSE 0
        END as push_added_revenue,
        CASE
            WHEN (iam_click_time IS NOT NULL AND iam_click_time <= purchase_time) THEN price
            ELSE 0
        END as iam_added_revenue
    FROM purchases_with_user_interaction_events
),

-- Group by purchase_event_id so we don't count purchase events twice.
grouped_purchase_events AS (
    SELECT purchase_event_id,
        ANY_VALUE(user_id) as user_id,
        TO_DOUBLE(MAX(email_added_revenue)) as email_added_revenue,
        TO_DOUBLE(MAX(push_added_revenue)) as push_added_revenue,
        TO_DOUBLE(MAX(iam_added_revenue)) as iam_added_revenue
    FROM purchases_within_time_frame
    GROUP BY purchase_event_id
),

-- Compute aggregate metrics for email
counted_total_email AS (
    SELECT
        COUNT(*) as transactions,
        (SELECT SUM(email_added_revenue) FROM grouped_purchase_events) as revenue,
        (SELECT COUNT(*) FROM unsubscribed_emails) as unsubscribes,
        (SELECT AVG(email_added_revenue) FROM grouped_purchase_events where email_added_revenue > 0) as average_price,
        (SELECT COUNT(*) FROM delivered_emails) as total_deliveries,
        (SELECT COUNT(*) FROM opened_emails) as total_opens,
        (SELECT COUNT(*) FROM clicked_emails) as total_clicks,
        (SELECT COUNT(DISTINCT user_id) FROM opened_emails) as total_unique_opens,
        (SELECT COUNT(DISTINCT user_id) FROM clicked_emails) as total_unique_clicks
    FROM grouped_purchase_events
    WHERE email_added_revenue > 0
),

-- Compute aggregate metrics for push
counted_total_push AS (
    SELECT
        COUNT(*) AS direct_opens,
        (SELECT SUM(push_added_revenue) FROM grouped_purchase_events) as revenue,
        (SELECT AVG(push_added_revenue) FROM grouped_purchase_events WHERE push_added_revenue > 0) as average_price,
        (SELECT COUNT(*) FROM grouped_purchase_events WHERE push_added_revenue > 0) as transactions,
        (SELECT COUNT(*) FROM push_merge) as total_opens,
        (SELECT COUNT(*) FROM push_merge) as total_clicks,
        (SELECT COUNT(*) FROM delivered_pushs) as total_deliveries,
        (SELECT COUNT(DISTINCT user_id) FROM push_merge) as total_unique_opens
  FROM opened_pushs
),

-- Compute aggregate metrics for in-app
counted_total_iam AS (
  SELECT COUNT(*) AS total_clicks,
    (SELECT SUM(iam_added_revenue) FROM grouped_purchase_events) AS revenue,
    (SELECT AVG(iam_added_revenue) FROM grouped_purchase_events WHERE iam_added_revenue > 0) AS average_price,
    (SELECT COUNT(*) FROM grouped_purchase_events WHERE iam_added_revenue > 0) AS transactions,
    (SELECT COUNT(DISTINCT user_id) FROM clicked_iam) AS total_unique_clicks
  FROM clicked_iam
)

-- Combine metrics from all channels and format the output
SELECT
    'Email' AS channel,
    total_deliveries,
    revenue,
    transactions,
    ROUND(TO_DOUBLE(average_price),2) AS average_price,
    Null AS direct_opens,
    total_opens,
    total_unique_opens,
    Null AS total_clicks,
    Null AS total_unique_clicks,
    unsubscribes
FROM counted_total_email
UNION
SELECT
    'Push' AS channel,
    total_deliveries,
    revenue,
    transactions,
    ROUND(TO_DOUBLE(average_price), 2) AS average_price,
    direct_opens,
    total_opens,
    total_unique_opens,
    Null AS total_clicks,
    Null AS total_unique_clicks,
    Null AS unsubscribes
FROM counted_total_push
UNION
SELECT
    'In-App' AS channel,
    Null AS total_deliveries,
    revenue,
    transactions,
    ROUND(TO_DOUBLE(average_price),2) AS average_price,
    Null AS direct_opens,
    Null AS total_opens,
    Null AS total_unique_opens,
    total_clicks,
    total_unique_clicks,
    Null AS unsubscribes
FROM counted_total_iam
ORDER BY channel ASC;
