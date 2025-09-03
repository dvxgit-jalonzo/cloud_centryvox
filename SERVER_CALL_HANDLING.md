# Server-Side Call Handling Implementation

## Overview
This document outlines the server-side changes needed to support proper incoming call handling when the Flutter app is terminated or backgrounded.

## Problem Solved
- **Race Condition**: App needs time to initialize after being woken up by push notification
- **Sequential Flow**: Server must wait for mobile client to be ready before bridging the call

## Updated API Endpoint: `/api/call-response`

### New Action Type: `accept_ready`

```javascript
// Example Express.js implementation
app.post('/api/call-response', async (req, res) => {
  const { server_call_id, extension, action, timestamp } = req.body;

  try {
    switch (action) {
      case 'accept':
        // Legacy: immediate acceptance (app was already running)
        await handleCallAccept(server_call_id, extension);
        break;

      case 'accept_ready':
        // New: app initialized and ready (from background/terminated)
        await handleCallAcceptReady(server_call_id, extension);
        break;

      case 'decline':
        await handleCallDecline(server_call_id, extension);
        break;

      case 'hangup':
        await handleCallHangup(server_call_id, extension);
        break;
    }

    res.json({ success: true });
  } catch (error) {
    console.error('Call response error:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});
```

## Call Flow Implementation

### 1. Incoming Call Initiation
```javascript
async function initiateIncomingCall(callerNumber, targetExtension) {
  // Step 1: Send push notification first
  const callId = generateUniqueId();
  
  await sendPushNotification(targetExtension, {
    type: 'incoming_call',
    call_id: callId,
    server_call_id: callId, // Your internal call tracking ID
    caller_name: getCallerName(callerNumber),
    caller_number: callerNumber
  });

  // Step 2: Store call state as "waiting_for_mobile"
  await storeCallState(callId, {
    status: 'waiting_for_mobile',
    caller: callerNumber,
    target: targetExtension,
    timestamp: Date.now(),
    timeout: Date.now() + 30000 // 30 second timeout
  });

  // Step 3: Set timeout to cancel call if no response
  setTimeout(() => cancelCallIfNotAccepted(callId), 30000);
}
```

### 2. Handle Mobile Ready Signal
```javascript
async function handleCallAcceptReady(serverCallId, extension) {
  const callState = await getCallState(serverCallId);
  
  if (!callState || callState.status !== 'waiting_for_mobile') {
    throw new Error('Invalid call state');
  }

  // Update call state
  await updateCallState(serverCallId, {
    status: 'mobile_ready',
    mobile_ready_time: Date.now()
  });

  // Bridge the call to mobile client
  await bridgeCallToMobile(callState.caller, extension);
  
  console.log(`📱 Mobile ${extension} ready - bridging call from ${callState.caller}`);
}
```

### 3. Call State Management
```javascript
// In-memory or database storage for call states
const callStates = new Map();

async function storeCallState(callId, state) {
  callStates.set(callId, state);
  // Also persist to database if needed
}

async function getCallState(callId) {
  return callStates.get(callId);
}

async function updateCallState(callId, updates) {
  const current = callStates.get(callId) || {};
  callStates.set(callId, { ...current, ...updates });
}
```

### 4. Asterisk Integration
```javascript
async function bridgeCallToMobile(callerNumber, targetExtension) {
  // Example using Asterisk ARI or AMI
  const channel = await asterisk.originateCall({
    endpoint: `PJSIP/${targetExtension}`,
    extension: callerNumber,
    context: 'incoming-calls',
    priority: 1,
    timeout: 30,
    callerId: callerNumber,
    variables: {
      CALL_TYPE: 'mobile_ready',
      ORIGINAL_CALLER: callerNumber
    }
  });

  console.log(`📞 Bridging call from ${callerNumber} to ${targetExtension}`);
  return channel;
}
```

## Timeout Handling

```javascript
async function cancelCallIfNotAccepted(callId) {
  const callState = await getCallState(callId);
  
  if (!callState) return;

  if (callState.status === 'waiting_for_mobile') {
    console.log(`⏰ Call ${callId} timed out - mobile never became ready`);
    
    // Send busy signal to caller
    await sendBusySignal(callState.caller);
    
    // Clean up call state
    callStates.delete(callId);
  }
}
```

## Push Notification Service

```javascript
async function sendPushNotification(extension, callData) {
  const fcmToken = await getFCMToken(extension);
  
  if (!fcmToken) {
    console.error(`No FCM token for extension ${extension}`);
    return false;
  }

  const message = {
    token: fcmToken,
    data: callData, // All data in data payload for background handling
    android: {
      priority: 'high',
      ttl: 30000, // 30 seconds
    },
    apns: {
      headers: {
        'apns-priority': '10',
        'apns-expiration': Math.floor(Date.now() / 1000) + 30
      },
      payload: {
        aps: {
          'content-available': 1, // Silent notification for background processing
        }
      }
    }
  };

  await admin.messaging().send(message);
  console.log(`📱 Push notification sent to extension ${extension}`);
}
```

## Testing Scenarios

### 1. App Running (Foreground)
- Push notification → App handles immediately → `accept` action → Bridge call

### 2. App Backgrounded  
- Push notification → App wakes → CallKit UI → Accept → Initialize → `accept_ready` → Bridge call

### 3. App Terminated
- Push notification → App launches → CallKit UI → Accept → Full initialization → `accept_ready` → Bridge call

## Error Handling

```javascript
// Handle various failure scenarios
async function handleCallFailures(callId, error) {
  const callState = await getCallState(callId);
  
  console.error(`Call ${callId} failed:`, error);
  
  // Send appropriate response to caller
  if (callState?.caller) {
    await sendCallFailureResponse(callState.caller);
  }
  
  // Clean up
  callStates.delete(callId);
}
```

## Monitoring & Metrics

```javascript
// Track call success rates and timing
const callMetrics = {
  total_calls: 0,
  successful_calls: 0,
  background_launches: 0,
  average_ready_time: 0
};

// Log metrics for each call
function logCallMetrics(callId, readyTime, success) {
  callMetrics.total_calls++;
  if (success) callMetrics.successful_calls++;
  
  const readyDuration = readyTime - callState.timestamp;
  if (readyDuration > 5000) callMetrics.background_launches++;
  
  console.log(`📊 Call metrics: ${JSON.stringify(callMetrics)}`);
}
```

## Implementation Checklist

- [ ] Update `/api/call-response` endpoint to handle `accept_ready` action
- [ ] Implement call state management system  
- [ ] Add timeout handling for mobile readiness
- [ ] Update push notification payload structure
- [ ] Integrate with Asterisk for delayed call bridging
- [ ] Add comprehensive logging and metrics
- [ ] Test all scenarios (foreground, background, terminated)

## Next Steps

1. **Test the Implementation**: Use the Flutter app changes with your updated server
2. **Monitor Call Success**: Track metrics to ensure the solution works reliably  
3. **Fine-tune Timeouts**: Adjust timing based on real-world performance
4. **Add Failsafes**: Handle edge cases like network failures during initialization