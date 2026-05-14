# Demo 02: CloudWatch Alarms + SNS Notifications — Alerting on the Four Golden Signals

## Overview

Metrics without alerting are like a smoke detector with no alarm — you can
see the data, but nobody gets notified when something goes wrong. CloudWatch
Alarms watch your metrics continuously and trigger actions when thresholds
are breached. SNS (Simple Notification Service) is the delivery engine that
routes those alerts to email, Slack, PagerDuty, or any HTTP endpoint.

This demo builds directly on Demo 01. The EC2 instance, IAM role, and
CloudWatch Agent from Demo 01 are reused. You will build a complete
alerting layer on top of the metrics already flowing.

**Real-world scenario:**
Your Node.js API server from Demo 01 is now in staging. Before promoting
to production, the team requires: CPU alerts at 80%, memory alerts at 85%,
disk alerts at 75%, and instance health alerts for any status check failure.
On-call engineers must receive email notifications within 1 minute of a
breach. You are building the alerting system from scratch.

**What this demo covers:**
- How CloudWatch Alarms work — states, evaluation periods, and thresholds
- How SNS topics route notifications to multiple subscribers
- Building alarms on all Four Golden Signals (completing what Demo 01 started)
- Alarm states — OK, ALARM, INSUFFICIENT_DATA — and what each means
- Composite Alarms — combining multiple alarms to reduce alert fatigue
- Testing alarms without waiting for real incidents
- Alarm best practices from Google SRE and AWS Well-Architected
- Open source equivalent — how this maps to Alertmanager + PagerDuty
- Cost implications and Free Tier boundaries

---

## Google SRE Alerting Principles — The Framework Behind This Demo

Before building any alarm, understand the principles that separate good
alerting from alert fatigue:

```
┌─────────────────────────────────────────────────────────────────────┐
│           Google SRE Alerting Principles                            │
├──────────────────────────────────────────────────────────────────────┤
│ 1. Alert on symptoms, not causes                                    │
│    Alert when users are affected — not on every metric blip         │
│    "High error rate" ✅  vs  "CPU at 70%" ❌                        │
├──────────────────────────────────────────────────────────────────────┤
│ 2. Every alert must be actionable                                   │
│    If the on-call engineer cannot do something about it → remove it │
│    Unactionable alerts train engineers to ignore all alerts         │
├──────────────────────────────────────────────────────────────────────┤
│ 3. Alerts should have a runbook                                     │
│    Every alarm description links to what to check and how to fix    │
├──────────────────────────────────────────────────────────────────────┤
│ 4. Minimize noise — use evaluation periods                          │
│    A single data point over threshold should not page anyone        │
│    Require N consecutive breaches before firing                     │
├──────────────────────────────────────────────────────────────────────┤
│ 5. Alert at the right threshold                                     │
│    Too low → alert fatigue. Too high → missed incidents             │
│    Start conservative, tighten based on real incident history       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## How CloudWatch Alarms Work — Core Concepts

### Alarm States

Every CloudWatch Alarm is always in exactly one of three states:

```
┌──────────────────────┬───────────────────────────────────────────────┐
│  State               │  Meaning                                      │
├──────────────────────┼───────────────────────────────────────────────┤
│  OK                  │  Metric is within the defined threshold        │
│  (green)             │  Everything is normal                         │
├──────────────────────┼───────────────────────────────────────────────┤
│  ALARM               │  Metric has breached the threshold            │
│  (red)               │  for the required number of periods           │
│                      │  Action is triggered (SNS notification sent)  │
├──────────────────────┼───────────────────────────────────────────────┤
│  INSUFFICIENT_DATA   │  Not enough data points to evaluate           │
│  (grey)              │  Alarm just created, metric stopped flowing,  │
│                      │  or evaluation period not yet complete        │
└──────────────────────┴───────────────────────────────────────────────┘
```

> **Why INSUFFICIENT_DATA matters:**
> A new alarm starts in INSUFFICIENT_DATA, not OK. If you create an alarm
> and immediately see INSUFFICIENT_DATA, that is normal — wait one full
> evaluation period. If it persists, the metric is not flowing (agent not
> running, wrong namespace, wrong dimension).

### Evaluation — How an Alarm Decides to Fire

```
Key parameters:
  Period          → length of each evaluation window (e.g. 60 seconds)
  Evaluation      → how many periods to evaluate (e.g. 3 periods = 3 minutes)
  Periods         →
  Datapoints to   → how many of those periods must breach the threshold
  Alarm           → (e.g. 2 out of 3)
  Threshold       → the value that triggers the alarm (e.g. > 80%)
  Comparison      → GreaterThanThreshold, LessThanThreshold, etc.

Example — CPU alarm:
  Period:              60 seconds
  Evaluation periods:  3
  Datapoints to alarm: 2
  Threshold:           80%

  This means: if CPUUtilization exceeds 80% in 2 out of any 3 consecutive
  1-minute periods → ALARM state → SNS notification sent

  Why 2 out of 3 instead of 1 out of 1?
  A single spike to 81% for 60 seconds may not be a real problem.
  Sustained high CPU (2 consecutive minutes) almost always is.
  This is the "minimize noise" SRE principle in practice.
```

### Alarm Actions

Actions are triggered on state transitions:

```
ON ALARM   → notify SNS topic → email / Slack / PagerDuty
ON OK      → notify SNS topic → "incident resolved" notification
ON INSUFF. → notify SNS topic → "data stopped flowing" notification
```

> **SRE best practice:** Always configure both ON ALARM and ON OK actions.
> Without an OK action, engineers never know when an incident self-resolved.
> In Alertmanager this is equivalent to the `resolved` notification.

### Open Source Equivalent

```
┌─────────────────────────────────┬───────────────────────────────────┐
│  Open Source (Prometheus stack) │  AWS CloudWatch                   │
├─────────────────────────────────┼───────────────────────────────────┤
│  Prometheus alert rules         │  CloudWatch Alarms                │
│  (YAML — for: expr: labels:)    │  (threshold + period + datapoints)│
├─────────────────────────────────┼───────────────────────────────────┤
│  Alertmanager                   │  CloudWatch Alarm Actions         │
│  routes, groups, silences       │  routes to SNS topics             │
├─────────────────────────────────┼───────────────────────────────────┤
│  Alertmanager receivers         │  SNS Subscriptions                │
│  (email, Slack, PagerDuty)      │  (email, HTTPS, Lambda, SQS)      │
├─────────────────────────────────┼───────────────────────────────────┤
│  for: [5m] (pending period)     │  Evaluation periods + datapoints  │
│  Prevents flapping alerts       │  "2 out of 3 periods" rule        │
├─────────────────────────────────┼───────────────────────────────────┤
│  Inhibition rules               │  Composite Alarms                 │
│  Suppress child alerts when     │  Combine alarms with AND/OR logic │
│  parent fires                   │  Suppress noise during incidents  │
├─────────────────────────────────┼───────────────────────────────────┤
│  group_wait / group_interval    │  No direct equivalent             │
│  Alert grouping and batching    │  SNS delivers immediately         │
└─────────────────────────────────┴───────────────────────────────────┘
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                           us-east-1                                  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │              EC2 (from Demo 01) — demo01-cw-metrics            │  │
│  │              CloudWatch Agent running                          │  │
│  └──────────────────────────────┬─────────────────────────────────┘  │
│                                 │ metrics (HTTPS 443)                │
│                                 ▼                                    │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                    Amazon CloudWatch                           │  │
│  │                                                                │  │
│  │  ┌──────────────────────────────────────────────────────────┐  │  │
│  │  │                    Alarms                                │  │  │
│  │  │                                                          │  │  │
│  │  │  demo01-cpu-alarm      CPUUtilization > 80% (2/3 min)   │  │  │
│  │  │  demo01-mem-alarm      mem_used_percent > 85% (2/3 min) │  │  │
│  │  │  demo01-disk-alarm     disk_used_percent > 75% (2/3 min)│  │  │
│  │  │  demo01-status-alarm   StatusCheckFailed >= 1 (1/1 min) │  │  │
│  │  │                                                          │  │  │
│  │  │  demo01-composite      ANY of above in ALARM state       │  │  │
│  │  └──────────────────────────────┬───────────────────────────┘  │  │
│  └─────────────────────────────────┼────────────────────────────── ┘  │
│                                    │ alarm action                    │
│                                    ▼                                 │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │                  Amazon SNS                                     │  │
│  │                                                                 │  │
│  │  Topic: demo01-alerts                                           │  │
│  │                                                                 │  │
│  │  Subscriptions:                                                 │  │
│  │  ├── Email    → your-email@example.com                          │  │
│  │  └── (Demo 04 adds Slack via Lambda)                            │  │
│  └─────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- Demo 01 completed — EC2 instance running with CloudWatch Agent active
- IAM user with `CloudWatchFullAccess`, `AmazonSNSFullAccess`
- AWS CLI v2 configured on local machine
- An email address to receive test notifications

**Verify Demo 01 metrics are flowing (run on local machine):**
```bash
# Confirm instance is running
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=demo01-cw-metrics" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name}' \
  --output table

# Confirm CWAgent metrics are present
aws cloudwatch list-metrics --namespace CWAgent \
  --query 'Metrics[].MetricName' --output table
```

**Expected:** Instance in `running` state, `mem_used_percent` and
`disk_used_percent` listed in CWAgent namespace.

---

## Lab Objectives

By the end of this demo, you will be able to:
1. ✅ Create an SNS topic and subscribe an email endpoint
2. ✅ Create CloudWatch Alarms on CPU, memory, disk, and status check metrics
3. ✅ Explain alarm states — OK, ALARM, INSUFFICIENT_DATA
4. ✅ Configure evaluation periods to reduce false positives
5. ✅ Test alarms by triggering real load and verifying email notifications
6. ✅ Create a Composite Alarm to reduce alert fatigue
7. ✅ Map alarms to all Four Golden Signals (completing Demo 01 coverage)

---

## Directory Structure

```
02-cloudwatch-alarms-sns/
├── README.md
└── scripts/
    ├── 01-create-sns-topic.sh          # SNS topic + email subscription
    ├── 02-create-alarms.sh             # All four metric alarms
    ├── 03-create-composite-alarm.sh    # Composite alarm
    ├── 04-test-alarms.sh               # Load simulation to trigger alarms
    └── 05-cleanup.sh                   # Full teardown
```

---

## Step 1: Create SNS Topic and Email Subscription

SNS (Simple Notification Service) is the messaging layer between CloudWatch
Alarms and the humans or systems that need to act on them. Think of it as
a notification bus — one alarm can fan out to many subscribers simultaneously.

### What SNS Is and Why It Exists

```
Without SNS:
  CloudWatch Alarm → directly emails you
  Problem: one alarm, one destination, no flexibility

With SNS:
  CloudWatch Alarm → SNS Topic → many subscribers simultaneously
  ├── Email (on-call engineer)
  ├── Email (team distribution list)
  ├── HTTPS (Slack webhook via Lambda)
  ├── SQS (ticketing system)
  └── Lambda (auto-remediation function)

SNS Topic = a named channel
SNS Subscription = a delivery endpoint attached to that channel
```

**Open source equivalent:**

```
SNS Topic        ↔  Alertmanager receiver group
SNS Subscription ↔  Alertmanager receiver (email/slack/pagerduty config)
```

### Console Steps — Create SNS Topic

**Navigate to:** SNS → Topics → Create topic

| Setting | Value | Why |
|---------|-------|-----|
| Type | Standard | Standard = at-least-once, unordered. FIFO = ordered, deduped (not needed for alerts) |
| Name | `demo01-alerts` | Named after the resource being monitored |
| Display name | `Demo01 Alerts` | Shown in email From field |
| Encryption | Disabled | Not required for alert notifications |
| Access policy | Basic (default) | Only CloudWatch needs to publish |

Click **Create topic** ✅

> **Why Standard and not FIFO?**
> Alert notifications do not require strict ordering. Standard topics have
> higher throughput and support email subscriptions — FIFO topics do not
> support email subscribers.

### Console Steps — Subscribe Email

**On the topic page:** Subscriptions tab → **Create subscription**

| Setting | Value |
|---------|-------|
| Protocol | Email |
| Endpoint | your-email@example.com |

Click **Create subscription**

**Check your email** — you will receive a confirmation email from AWS.
Click **Confirm subscription** in that email.

> ⚠️ **The subscription is pending until confirmed.** Alarms will not
> deliver notifications to an unconfirmed email subscription. This is
> the most common reason test notifications do not arrive.

**Verify subscription is confirmed:**

In SNS console → your topic → Subscriptions tab →
Status must show **Confirmed** (not PendingConfirmation).

### Key CLI Commands

```bash
# Create SNS topic
TOPIC_ARN=$(aws sns create-topic --name demo01-alerts \
  --query 'TopicArn' --output text)
echo "Topic ARN: $TOPIC_ARN"

# Subscribe email (replace with your address)
aws sns subscribe \
  --topic-arn $TOPIC_ARN \
  --protocol email \
  --notification-endpoint your-email@example.com

# Check subscription status (after confirming email)
aws sns list-subscriptions-by-topic \
  --topic-arn $TOPIC_ARN \
  --query 'Subscriptions[].{Protocol:Protocol,Status:SubscriptionArn}' \
  --output table
```

> ⚠️ Run on **local machine** — not on the EC2 instance.

---

## Step 2: Create CloudWatch Alarms

We create four alarms — one per Golden Signal category. Each alarm is
configured with evaluation periods to prevent false positives from
brief metric spikes.

### Understanding the Alarm Parameters

Before building each alarm, understand what each parameter controls:

```
┌─────────────────────┬────────────────────────────────────────────────┐
│ Parameter           │ What it controls                               │
├─────────────────────┼────────────────────────────────────────────────┤
│ Metric              │ Which metric to watch (namespace + name + dim) │
│ Statistic           │ Average / Maximum / p99 — how to aggregate     │
│ Period              │ Length of each evaluation window (seconds)     │
│ Evaluation periods  │ How many periods to look at                    │
│ Datapoints to alarm │ How many must breach threshold (M of N)        │
│ Threshold           │ The value that defines breach                  │
│ Comparison operator │ GreaterThan / LessThan / etc.                  │
│ Treat missing data  │ What to do when no data arrives                │
└─────────────────────┴────────────────────────────────────────────────┘
```

**Missing data treatment — important choice:**

```
missing → notBreaching  Use when: metric gap means resource stopped
                        (e.g. instance terminated = healthy)
                        Agent stopped sending = treat as OK

missing → breaching     Use when: metric gap is itself a problem
                        (e.g. no heartbeat = something is wrong)

missing → ignore        Use when: gaps are expected (maintenance windows)

missing → evaluating    Use when: you want strict evaluation
                        (treat gap as a data point that could breach)

For this demo: use notBreaching for all alarms
Reason: if the agent stops, we handle that with a separate status alarm
```

### Alarm 1: CPU Utilization — Traffic + Saturation Signal

**Navigate to:** CloudWatch → Alarms → Create alarm → Select metric

```
Metric:             AWS/EC2 → Per-Instance Metrics → CPUUtilization
Instance:           demo01-cw-metrics (your instance)
Statistic:          Average
Period:             1 minute  (requires detailed monitoring — enabled in Demo 01)
```

**Conditions:**
```
Threshold type:     Static
Condition:          Greater than
Threshold:          80

Additional configuration:
  Datapoints to alarm:  2 out of 3
  Missing data:         Treat as not breaching
```

**Why 80% and not 90% or 100%?**
```
At 100%: threads are already starving — users are affected now
At 90%:  very little headroom — latency spiking — too late to act
At 80%:  enough headroom to investigate and scale before users feel it
         This is the standard SRE threshold for CPU saturation warnings
```

**Why Average and not Maximum?**
```
Maximum fires on every brief spike — high noise
Average sustained above 80% means the instance is genuinely loaded
Use Maximum for a separate "critical" alarm at 95%+ if needed
```

**Configure actions:**
```
Alarm state trigger:  In alarm
SNS topic:            demo01-alerts
```

Also add an OK action:
```
Alarm state trigger:  OK
SNS topic:            demo01-alerts
```

**Alarm name:** `demo01-cpu-alarm`

**Alarm description:**
```
CPU utilization above 80% for 2 of 3 minutes on demo01-cw-metrics.
Check: top, htop, or CloudWatch metrics for process breakdown.
Action: Consider scaling up or investigating runaway processes.
```

> **Why write a description?** At 3 AM the on-call engineer reads this
> description in the email notification. A good description saves 5 minutes
> of "what does this alarm mean and what do I check first?"

Click **Create alarm** ✅

### Alarm 2: Memory Utilization — Saturation Signal

**Navigate to:** CloudWatch → Alarms → Create alarm → Select metric

```
Metric:             CWAgent → ImageId, InstanceId, InstanceType
                    → mem_used_percent for your instance
Statistic:          Average
Period:             1 minute
```

**Conditions:**
```
Threshold:          85
Datapoints to alarm: 2 out of 3
Missing data:       Treat as not breaching
```

**Why 85% for memory and not 80%?**
```
Memory usage is less elastic than CPU — applications reserve memory on
startup and hold it. A Java app with a 512MB heap always shows ~50%
memory used even under no load. Set the threshold high enough to avoid
constant false positives from normal application behavior.

85% gives a clear signal of genuine memory pressure before OOM-kill.
```

**Actions:** Both ALARM and OK → `demo01-alerts`

**Alarm name:** `demo01-mem-alarm`

**Description:**
```
Memory usage above 85% on demo01-cw-metrics.
Check: free -h, ps aux --sort=-%mem on the instance.
Action: Investigate memory-hungry processes or increase instance size.
```

### Alarm 3: Disk Utilization — Saturation Signal

**Navigate to:** CloudWatch → Alarms → Create alarm → Select metric

```
Metric:             CWAgent → ImageId, InstanceId, InstanceType, device, fstype, path
                    → disk_used_percent where path = /
Statistic:          Average
Period:             5 minutes  (disk fills slowly — 5-min period is sufficient)
```

**Conditions:**
```
Threshold:          75
Datapoints to alarm: 2 out of 3
Missing data:       Treat as not breaching
```

**Why 75% for disk?**
```
Disk filling is gradual but catastrophic when it hits 100%:
  At 100%: application cannot write logs, temp files, or data → crashes
  At 90%:  only 10% headroom — cleanup takes time — risky
  At 75%:  enough warning to investigate before any service impact

Linux filesystems also reserve 5% for root — effective limit is 95%.
Alert at 75% to give plenty of time for log rotation, cleanup, or resize.
```

**Why 5-minute period for disk?**
```
Disk rarely fills in under 5 minutes (unless a runaway log writer).
5-minute periods reduce the metric stream cost slightly.
For application log explosion scenarios, consider a separate 1-min alarm at 90%.
```

**Actions:** Both ALARM and OK → `demo01-alerts`

**Alarm name:** `demo01-disk-alarm`

**Description:**
```
Disk usage above 75% on / filesystem of demo01-cw-metrics.
Check: df -h, du -sh /* | sort -rh on the instance.
Action: Clear logs, rotate files, or resize the EBS volume.
```

### Alarm 4: Status Check Failed — Error Signal

This alarm covers the **Errors** Golden Signal — the one not covered in Demo 01.

Status checks are performed by AWS every minute automatically:

```
StatusCheckFailed_Instance (instance status check):
  Checks: OS is running, network interface is reachable
  Fails when: kernel panic, network misconfiguration, OS crash
  Action: Reboot the instance

StatusCheckFailed_System (system status check):
  Checks: underlying hardware and AWS infrastructure
  Fails when: hardware failure, network connectivity issue at AWS level
  Action: Stop and start the instance (moves to new hardware)

StatusCheckFailed (combined):
  = 1 if EITHER instance OR system check fails
  = 0 when both pass
```

**Navigate to:** CloudWatch → Alarms → Create alarm → Select metric

```
Metric:             AWS/EC2 → Per-Instance Metrics → StatusCheckFailed
                    for your instance
Statistic:          Maximum  (not Average — even one failure is critical)
Period:             1 minute
```

**Conditions:**
```
Threshold type:     Static
Condition:          Greater than or equal to
Threshold:          1

Datapoints to alarm: 1 out of 1   ← fire immediately on first failure
Missing data:       Treat as breaching  ← no data = something is very wrong
```

**Why 1 out of 1 and not 2 out of 3 here?**
```
CPU at 81% for 60 seconds → probably fine, wait and see
Instance status check failed → the instance may be down RIGHT NOW

Status check failures are binary — the instance either responds or it does not.
There is no benefit in waiting for 3 consecutive failures before alerting.
Alert on the first failure and investigate immediately.
```

**Why Maximum and not Average?**
```
StatusCheckFailed is 0 or 1.
If it is 1 for even one second in a 60-second period:
  Average might show 0.016 → below threshold → alarm misses it
  Maximum shows 1 → alarm fires correctly

Always use Maximum for binary (0/1) metrics.
```

**Actions:** Both ALARM and OK → `demo01-alerts`

**Alarm name:** `demo01-status-alarm`

**Description:**
```
EC2 status check failing on demo01-cw-metrics.
Instance or system check has failed — instance may be unreachable.
Check: EC2 console → Status checks tab.
Action: Reboot for instance check failure. Stop/Start for system check failure.
```

### Key CLI Commands — Create All Alarms

```bash
# Run on local machine
# Set these variables first
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=demo01-cw-metrics" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

TOPIC_ARN=$(aws sns list-topics \
  --query 'Topics[?ends_with(TopicArn,`demo01-alerts`)].TopicArn' \
  --output text)

# CPU alarm
aws cloudwatch put-metric-alarm \
  --alarm-name demo01-cpu-alarm \
  --alarm-description "CPU above 80% for 2/3 minutes" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --datapoints-to-alarm 2 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions $TOPIC_ARN \
  --ok-actions $TOPIC_ARN

# Memory alarm
aws cloudwatch put-metric-alarm \
  --alarm-name demo01-mem-alarm \
  --alarm-description "Memory above 85% for 2/3 minutes" \
  --metric-name mem_used_percent \
  --namespace CWAgent \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --datapoints-to-alarm 2 \
  --threshold 85 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions $TOPIC_ARN \
  --ok-actions $TOPIC_ARN

# Disk alarm
aws cloudwatch put-metric-alarm \
  --alarm-name demo01-disk-alarm \
  --alarm-description "Disk above 75% on root filesystem" \
  --metric-name disk_used_percent \
  --namespace CWAgent \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
              Name=path,Value=/ \
              Name=device,Value=nvme0n1p1 \
              Name=fstype,Value=xfs \
  --statistic Average \
  --period 300 \
  --evaluation-periods 3 \
  --datapoints-to-alarm 2 \
  --threshold 75 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions $TOPIC_ARN \
  --ok-actions $TOPIC_ARN

# Status check alarm
aws cloudwatch put-metric-alarm \
  --alarm-name demo01-status-alarm \
  --alarm-description "EC2 status check failing" \
  --metric-name StatusCheckFailed \
  --namespace AWS/EC2 \
  --dimensions Name=InstanceId,Value=$INSTANCE_ID \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 1 \
  --datapoints-to-alarm 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data breaching \
  --alarm-actions $TOPIC_ARN \
  --ok-actions $TOPIC_ARN
```

> **Note on disk alarm dimensions:** The CWAgent disk metric requires all
> four dimensions: InstanceId, path, device, and fstype. If any dimension
> is missing or wrong, CloudWatch cannot match the metric and the alarm
> stays in INSUFFICIENT_DATA. Find the exact dimension values from:
> CloudWatch → Metrics → CWAgent → ImageId, InstanceId, InstanceType,
> device, fstype, path → look at the row for path=/

**Verify all alarms were created:**
```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix demo01 \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Metric:MetricName}' \
  --output table
```

**Expected output:**
```
--------------------------------------------------------------
|                      DescribeAlarms                        |
+----------------------+---------+---------------------------+
|  Name                |  State  |  Metric                   |
+----------------------+---------+---------------------------+
|  demo01-cpu-alarm    |  OK     |  CPUUtilization           |
|  demo01-disk-alarm   |  OK     |  disk_used_percent        |
|  demo01-mem-alarm    |  OK     |  mem_used_percent         |
|  demo01-status-alarm |  OK     |  StatusCheckFailed        |
+----------------------+---------+---------------------------+
```

> If any alarm shows `INSUFFICIENT_DATA`, the metric is not flowing.
> Check: agent running, correct namespace, correct dimensions.

---

## Step 3: Create Composite Alarm

A Composite Alarm combines multiple alarms using AND/OR logic. It fires
only when its rule evaluates to true — and crucially, it does not re-evaluate
the underlying metrics. It only watches alarm states.

### Why Composite Alarms?

```
Without Composite Alarm:
  CPU fires    → email 1
  Memory fires → email 2
  Disk fires   → email 3
  All at once during a bad incident → 3 separate emails in 60 seconds
  On-call engineer: overwhelmed, context-switching, missing the picture

With Composite Alarm:
  CPU fires + Memory fires + Disk fires
  → Composite evaluates: ANY of the three is in ALARM
  → ONE notification sent by the composite
  → Individual alarms still track state
  → Engineer sees: "system under stress" not "3 separate problems"
```

**Open source equivalent:**
```
Alertmanager group_by + group_wait:
  group_by: [alertname, instance]  → groups related alerts
  group_wait: 30s                  → waits before sending grouped notification

Composite Alarm is simpler — it suppresses child alarm notifications
and fires a single composite notification instead.
```

### Console Steps

**Navigate to:** CloudWatch → Alarms → Create alarm → **Composite alarm**

**Alarm rule:**
```
ALARM("demo01-cpu-alarm") OR
ALARM("demo01-mem-alarm") OR
ALARM("demo01-disk-alarm") OR
ALARM("demo01-status-alarm")
```

**Actions:**
```
In alarm → demo01-alerts SNS topic
OK       → demo01-alerts SNS topic
```

> **Important:** Suppress individual alarm notifications when composite
> fires. In each of the four alarms created in Step 2, you can optionally
> remove the SNS action and rely solely on the composite for notifications.
> For this demo, keep both — so you can see which individual alarm fired
> in the notification.

**Alarm name:** `demo01-composite`

**Description:**
```
At least one of the Four Golden Signal alarms is in ALARM state.
Check individual alarms: demo01-cpu-alarm, demo01-mem-alarm,
demo01-disk-alarm, demo01-status-alarm for details.
```

### Key CLI Command

```bash
aws cloudwatch put-composite-alarm \
  --alarm-name demo01-composite \
  --alarm-description "Any Golden Signal alarm is firing" \
  --alarm-rule 'ALARM("demo01-cpu-alarm") OR ALARM("demo01-mem-alarm") OR ALARM("demo01-disk-alarm") OR ALARM("demo01-status-alarm")' \
  --alarm-actions $TOPIC_ARN \
  --ok-actions $TOPIC_ARN
```

---

## Step 4: Test the Alarms

Testing alarms before a real incident is mandatory. You want to confirm:
1. The alarm transitions to ALARM state correctly
2. The SNS email arrives within the expected time
3. The email content is useful — subject, description, metric value

### Method 1: Force Alarm State (Instant Test — No Load Required)

CloudWatch lets you manually set an alarm state for testing. This bypasses
metric evaluation entirely — the alarm goes to ALARM immediately.

**Console:** CloudWatch → Alarms → select `demo01-cpu-alarm`
→ Actions → **Set alarm state**
→ State: **In alarm**
→ Reason: "Testing alarm notification delivery"
→ **Set state**

Check your email — notification should arrive within 30 seconds.

**CLI equivalent:**
```bash
# Force alarm into ALARM state for testing
aws cloudwatch set-alarm-state \
  --alarm-name demo01-cpu-alarm \
  --state-value ALARM \
  --state-reason "Testing notification delivery"

# Reset back to OK after testing
aws cloudwatch set-alarm-state \
  --alarm-name demo01-cpu-alarm \
  --state-value OK \
  --state-reason "Test complete"
```

> This is the fastest way to test that SNS delivery is working.
> Use it before every production alarm deployment.

### Method 2: Trigger Real Load (Full End-to-End Test)

This tests the complete pipeline: metric → threshold → alarm → SNS → email.

**On the EC2 instance (via EC2 Instance Connect):**
```bash
# Stress CPU above 80% for 5 minutes
# Alarm fires after 2 consecutive 1-minute periods above 80%
# Expected: alarm fires ~2 minutes after stress starts
stress-ng --cpu 2 --timeout 300s &
echo "Stress started — check email in ~2-3 minutes"
```

**Watch the alarm state change in real time:**

**Console:** CloudWatch → Alarms → `demo01-cpu-alarm`

Watch the state transition:
```
INSUFFICIENT_DATA (if new)
  ↓  (after first metric data point arrives)
OK
  ↓  (after 2 consecutive minutes above 80%)
ALARM  ← email arrives here
  ↓  (after stress stops and 2 consecutive minutes below 80%)
OK     ← recovery email arrives here
```

**Timeline you should expect:**
```
T+0:00  stress-ng starts
T+1:00  first 1-minute data point above 80% collected
T+2:00  second 1-minute data point above 80% → ALARM fires
T+2:30  email arrives in your inbox (SNS delivery ~30 seconds)
T+5:00  stress-ng stops automatically
T+6:00  first data point below 80%
T+7:00  second data point below 80% → OK state → recovery email
```

### What the Notification Email Looks Like

```
From:    ALARM: "demo01-cpu-alarm" in US East (N. Virginia)
Subject: ALARM: "demo01-cpu-alarm" in US East (N. Virginia)

You are receiving this email because your Amazon CloudWatch Alarm
"demo01-cpu-alarm" in the US East (N. Virginia) region has entered
the ALARM state, because "CPU above 80% for 2/3 minutes" at
"2025-01-15 10:05:00 UTC".

Alarm Details:
  Name:        demo01-cpu-alarm
  Description: CPU above 80% for 2/3 minutes on demo01-cw-metrics.
               Check: top, htop on instance.
  State Change: OK -> ALARM
  Reason:      Threshold Crossed: 2 datapoints [88.4, 91.2] were
               greater than the threshold (80.0).

Threshold:     CPUUtilization > 80 for 2 datapoints within 3 periods
               of 60 seconds (2 minutes)
Monitored:     InstanceId = i-0ef19836def38410c
```

> **What makes this notification actionable:**
> The email shows the actual values (88.4%, 91.2%) that triggered the alarm,
> not just "threshold breached." The description tells the engineer exactly
> what to check. This is why alarm descriptions matter.

---

## Step 5: View Alarms in CloudWatch Console

### Alarms Overview Page

**Navigate to:** CloudWatch → Alarms → All alarms

```
Console layout:
  Filter bar: All alarms | In alarm | OK | Insufficient data
  List: Alarm name | State | Condition | Actions | Last state change

State indicators:
  🔴 Red bell     → ALARM (action triggered)
  🟢 Green check  → OK (within threshold)
  ⚪ Grey circle  → INSUFFICIENT_DATA
```

### Alarm Detail Page

Click any alarm to see:

```
Tabs:
  Details    → configuration — metric, threshold, periods, actions
  History    → state change log — every transition with timestamp and reason
  Actions    → SNS topics configured for each state transition

Graph section:
  Shows the metric with the threshold line overlaid
  Red shading where metric exceeded threshold
  State change markers on the timeline
```

> **The History tab is your incident timeline.** During post-incident
> review, the alarm history shows exactly when the alarm fired, what
> value triggered it, and when it recovered. This is the CloudWatch
> equivalent of Alertmanager's alert history.

---

## Step 6: Four Golden Signals — Now Fully Covered

With Demo 02 complete, all four signals have alarm coverage:

```
┌────────────────┬──────────────────────────────────────────────────────┐
│ Golden Signal  │ Alarm Coverage                                       │
├────────────────┼──────────────────────────────────────────────────────┤
│ LATENCY        │ ⚠️  Not yet — needs application instrumentation      │
│                │ Demo 06 (X-Ray) and Demo 11 (App Signals)            │
├────────────────┼──────────────────────────────────────────────────────┤
│ TRAFFIC        │ ✅ demo01-cpu-alarm                                  │
│                │    CPUUtilization > 80% (2/3 min) → ALARM            │
│                │    NetworkIn/Out available — alarm added in Demo 04  │
├────────────────┼──────────────────────────────────────────────────────┤
│ ERRORS         │ ✅ demo01-status-alarm                               │
│                │    StatusCheckFailed >= 1 (1/1 min) → ALARM          │
│                │    First time Errors signal is fully covered         │
├────────────────┼──────────────────────────────────────────────────────┤
│ SATURATION     │ ✅ demo01-mem-alarm                                  │
│                │    mem_used_percent > 85% (2/3 min) → ALARM          │
│                │ ✅ demo01-disk-alarm                                 │
│                │    disk_used_percent > 75% (2/3 min) → ALARM         │
│                │ ✅ demo01-cpu-alarm (dual purpose)                   │
└────────────────┴──────────────────────────────────────────────────────┘

Coverage: 3/4 signals with active alarms ✅
Latency: Demo 06 (X-Ray tracing)
```

---

## Cost Estimate

| Component | Free Tier | After Free Tier | This Demo |
|-----------|-----------|-----------------|-----------|
| CloudWatch Alarms (first 10) | 10 alarms free | $0.10/alarm/month | $0 (5 alarms — within free tier) |
| Composite Alarm | Not in free tier | $0.50/alarm/month | $0.50 |
| SNS Topic | Free | Free | $0 |
| SNS Email notifications (first 1000) | 1000/month free | $2.00 per 100k | $0 |
| SNS HTTPS notifications (first 100k) | 100k/month free | $0.60 per 1M | $0 |

**Estimated total: ~$0.50/month** (composite alarm only)

**Cost optimization:**
- Stay within 10 standard alarms — Free Tier covers them
- Composite alarm ($0.50) is worth the cost — reduces notification noise
- Delete test alarms after demo — each alarm over 10 costs $0.10/month
- Use alarm suppression during maintenance windows — prevents false ALARM
  state notifications without deleting and recreating alarms

---

## Verify Final State

**Console verification (high level):**
- CloudWatch → Alarms → All alarms → confirm 5 alarms show state `OK`
- SNS → Topics → `demo01-alerts` → confirm email subscription `Confirmed`
- Test one alarm with `Set alarm state` → confirm email arrives

**CLI verification (run on local machine):**
```bash
# All alarms in OK state
aws cloudwatch describe-alarms \
  --alarm-name-prefix demo01 \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}' \
  --output table

# SNS subscription confirmed
aws sns list-subscriptions-by-topic \
  --topic-arn $TOPIC_ARN \
  --query 'Subscriptions[].{Protocol:Protocol,Status:SubscriptionArn}' \
  --output table
```

---

## Cleanup — Avoid Overnight Charges

### Console Steps

1. **CloudWatch** → Alarms → Select all `demo01-*` alarms → Actions → **Delete**
2. **SNS** → Topics → `demo01-alerts` → **Delete topic**

### CLI Cleanup

```bash
# Delete all alarms
aws cloudwatch delete-alarms \
  --alarm-names demo01-cpu-alarm demo01-mem-alarm \
                demo01-disk-alarm demo01-status-alarm demo01-composite
echo "Alarms deleted ✅"

# Get topic ARN and delete
TOPIC_ARN=$(aws sns list-topics \
  --query 'Topics[?ends_with(TopicArn,`demo01-alerts`)].TopicArn' \
  --output text)
aws sns delete-topic --topic-arn $TOPIC_ARN
echo "SNS topic deleted ✅"

# Keep EC2 instance and CloudWatch Agent running for Demo 03
# OR terminate if done for the day:
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=demo01-cw-metrics" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
echo "EC2 instance terminated ✅"
```

> **CloudWatch metric data and alarm history are retained after deletion**
> — no additional cleanup needed. Historical data does not incur cost.

---

## Lessons Learned

### Confirm SNS Email Subscription Before Testing Alarms

The subscription is in `PendingConfirmation` state until you click the
link in the confirmation email. Alarms will fire and SNS will attempt
delivery — but the email will not arrive at an unconfirmed subscription.
Always verify `Confirmed` status in the SNS console before running tests.

### Disk Alarm Requires All Four CWAgent Dimensions

The `disk_used_percent` metric from CWAgent has four dimensions: `InstanceId`,
`path`, `device`, and `fstype`. If any dimension is missing or incorrect in
the alarm definition, CloudWatch cannot match the metric and the alarm
stays in `INSUFFICIENT_DATA` indefinitely. Find the exact dimension values
from the CloudWatch Metrics browser before creating the alarm via CLI.

### Use Maximum Statistic for Binary Metrics

`StatusCheckFailed` is 0 or 1. Using Average on a binary metric can
produce values like 0.016 — which never crosses a threshold of 1.
Always use Maximum for any metric that is a flag (0/1), presence indicator,
or count where even one occurrence matters.

### Missing Data Treatment Changes Alarm Behavior Significantly

`notBreaching` (default) means gaps in data are treated as normal —
the alarm stays OK when data stops. `breaching` means gaps trigger the
alarm — useful for heartbeat-style monitoring where no data IS the problem.
Choose deliberately — the wrong setting causes either false positives
(breaching on maintenance windows) or missed incidents (notBreaching when
the agent crashes).

### Set Alarm State Is the Fastest Testing Tool

`set-alarm-state` bypasses metric evaluation entirely and transitions
the alarm immediately. Use it to verify SNS delivery, email content,
and notification routing before a real incident proves your alerting
is misconfigured. This is equivalent to sending a test alert in
Alertmanager using `amtool alert add`.

### Always Add OK Actions Alongside ALARM Actions

Without an OK action, the on-call engineer never receives a recovery
notification. They continue watching the system not knowing if the
incident resolved itself or requires continued attention. In Alertmanager
this is the `resolved` notification. In CloudWatch it is the OK action
on the SNS topic — configure it on every alarm.

---

## Quick CLI Reference

| What you need | Command |
|---------------|---------|
| List all alarms | `aws cloudwatch describe-alarms --alarm-name-prefix demo01` |
| Force alarm state for testing | `aws cloudwatch set-alarm-state --alarm-name ... --state-value ALARM --state-reason "..."` |
| Create/update an alarm | `aws cloudwatch put-metric-alarm --alarm-name ...` |
| Create composite alarm | `aws cloudwatch put-composite-alarm --alarm-rule 'ALARM("x") OR ALARM("y")'` |
| Delete alarms | `aws cloudwatch delete-alarms --alarm-names ...` |
| List SNS topics | `aws sns list-topics` |
| List subscriptions | `aws sns list-subscriptions-by-topic --topic-arn ...` |

---

## What's Next

**Demo 03: CloudWatch Logs + Log Insights**

Metrics tell you something is wrong. Logs tell you why. In Demo 03 you
will ship application logs from the EC2 instance to CloudWatch Logs,
write Log Insights queries to find errors and patterns, and create
metric filters that generate CloudWatch metrics directly from log events —
bridging the gap between the logging and metrics pillars.