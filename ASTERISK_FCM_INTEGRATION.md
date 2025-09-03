# Asterisk FCM Integration for Terminated App Calls

## 🎯 The Real-World Solution

This implementation solves the fundamental challenge: **How to receive calls when your app is terminated?**

Just like WhatsApp, Telegram, and other modern apps, we use Firebase Cloud Messaging (FCM) to wake up terminated apps and show native call interfaces.

## ⚡ Architecture Overview

### The Problem
- **Traditional approach**: App maintains persistent connection to Asterisk/Janus
- **When app terminates**: No connection = no incoming calls  
- **Background services**: Drain battery and unreliable on modern mobile OS

### The Solution
1. **FCM Push First**: Server sends FCM → App wakes up → Shows CallKit
2. **User Response**: Accept/decline sent immediately to server via HTTP
3. **Lazy Janus**: Only connect to Janus AFTER user accepts
4. **Server Bridges**: Asterisk manages call state and bridges after acceptance

## 🔄 Complete Call Flow

### When App is Terminated
```
Caller dials extension → Asterisk receives call → Sends FCM push
                                    ↓
FCM wakes app → Shows CallKit UI → User sees incoming call
                                    ↓
User accepts → HTTP response to server → Server bridges call
                                    ↓
App initializes Janus → Registers with SIP → Receives bridged call
```

### Benefits
- ✅ **Zero battery drain** (no background connections)
- ✅ **Instant wake** (FCM is highly optimized)
- ✅ **Production tested** (same pattern as WhatsApp)
- ✅ **Platform native** (iOS CallKit, Android CallScreen)

## Server-Side Implementation

### 1. FCM Token Registration API

Create an endpoint to register/unregister FCM tokens:

```javascript
// Example Express.js implementation
const express = require('express');
const admin = require('firebase-admin');

// Initialize Firebase Admin SDK
const serviceAccount = require('./path/to/your/firebase-service-account-key.json');
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const app = express();
app.use(express.json());

// Store extension-to-token mappings (use a database in production)
const extensionTokens = new Map();

// Register FCM token
app.post('/api/register-fcm-token', (req, res) => {
  const { extension, fcm_token, platform } = req.body;
  
  if (!extension || !fcm_token) {
    return res.status(400).json({ error: 'Missing extension or FCM token' });
  }
  
  extensionTokens.set(extension, {
    token: fcm_token,
    platform,
    registered_at: new Date()
  });
  
  console.log(`FCM token registered for extension ${extension}`);
  res.json({ success: true });
});

// Unregister FCM token
app.post('/api/unregister-fcm-token', (req, res) => {
  const { extension, fcm_token } = req.body;
  
  if (extensionTokens.has(extension)) {
    extensionTokens.delete(extension);
    console.log(`FCM token unregistered for extension ${extension}`);
  }
  
  res.json({ success: true });
});

// Function to send FCM push notification for incoming call
async function sendCallNotification(extensionNumber, callerName, callerNumber, callId) {
  const tokenData = extensionTokens.get(extensionNumber);
  
  if (!tokenData) {
    console.log(`No FCM token found for extension ${extensionNumber}`);
    return false;
  }
  
  const message = {
    token: tokenData.token,
    data: {
      type: 'incoming_call',
      call_id: callId,
      caller_name: callerName || 'Unknown Caller',
      caller_number: callerNumber || 'Unknown',
      extension: extensionNumber
    },
    android: {
      priority: 'high',
      notification: {
        title: `Incoming call from ${callerName || callerNumber}`,
        body: 'Touch to answer',
        icon: 'call_icon',
        sound: 'default',
        priority: 'high',
        channelId: 'incoming_calls'
      }
    },
    apns: {
      payload: {
        aps: {
          alert: {
            title: `Incoming call from ${callerName || callerNumber}`,
            body: 'Touch to answer'
          },
          sound: 'default',
          'content-available': 1,
          'mutable-content': 1
        }
      }
    }
  };
  
  try {
    const response = await admin.messaging().send(message);
    console.log(`FCM notification sent successfully: ${response}`);
    return true;
  } catch (error) {
    console.error('Error sending FCM notification:', error);
    return false;
  }
}

app.listen(8080, () => {
  console.log('FCM service running on port 8080');
});

module.exports = { sendCallNotification };
```

### 2. Asterisk Integration

#### Option A: Asterisk AGI Script

Create an AGI script that triggers when calls come in:

```python
#!/usr/bin/env python3
import requests
import sys
import uuid
from asterisk.agi import AGI

def send_fcm_notification(extension, caller_name, caller_number):
    call_id = str(uuid.uuid4())
    
    try:
        response = requests.post('http://localhost:8080/api/send-call-notification', 
            json={
                'extension': extension,
                'caller_name': caller_name,
                'caller_number': caller_number,
                'call_id': call_id
            },
            timeout=5
        )
        return response.status_code == 200
    except Exception as e:
        print(f"Error sending FCM: {e}")
        return False

if __name__ == '__main__':
    agi = AGI()
    
    extension = agi.get_variable('EXTEN')
    caller_id = agi.get_variable('CALLERID(name)')
    caller_num = agi.get_variable('CALLERID(num)')
    
    # Send FCM notification
    if send_fcm_notification(extension, caller_id, caller_num):
        agi.verbose("FCM notification sent successfully")
    else:
        agi.verbose("Failed to send FCM notification")
```

#### Option B: Asterisk Extensions.conf

Add to your dialplan:

```
[your-context]
exten => _XXXX,1,NoOp(Incoming call to ${EXTEN})
same => n,AGI(send_fcm.py)
same => n,Dial(SIP/${EXTEN},30)
same => n,Hangup()
```

### 3. Firebase Project Setup

1. **Create Firebase Project**:
   - Go to [Firebase Console](https://console.firebase.google.com/)
   - Create new project or use existing
   - Enable Cloud Messaging

2. **Generate Service Account Key**:
   - Go to Project Settings > Service Accounts
   - Generate new private key
   - Download JSON file for server use

3. **Configure App**:
   - Your `google-services.json` is already configured
   - Ensure package name matches: `net.diavox.cloud_centryvox`

## Testing the Integration

1. **Start your Asterisk server with FCM integration**
2. **Run the Flutter app and scan QR code to register**
3. **Close/terminate the Flutter app completely**
4. **Make a call to the registered extension**
5. **You should see CallKit incoming call notification**
6. **Answer the call - app will launch and connect via Janus**

## Important Notes

1. **Call Flow**: When app is terminated and call is answered:
   - FCM shows CallKit notification
   - User answers call
   - App launches and initializes Janus
   - App registers with SIP server
   - App accepts the waiting call

2. **Timing**: There might be a 2-3 second delay between answering and audio connection while Janus initializes.

3. **Error Handling**: Always implement proper error handling for network issues, registration failures, etc.

4. **Security**: In production, implement proper authentication and validation for the FCM registration endpoints.

5. **Database**: Use a proper database instead of in-memory storage for extension-to-token mappings.

## Troubleshooting

- **No push notifications**: Check FCM token registration and server logs
- **CallKit not showing**: Verify iOS permissions and background modes
- **Call answer fails**: Check Janus initialization and SIP registration
- **Audio issues**: Ensure proper media permissions and constraints