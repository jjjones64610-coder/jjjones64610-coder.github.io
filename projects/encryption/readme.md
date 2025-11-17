
# Encryption Activity Reflection


## Part 1: Key Exchange

My Key:7
My Partner's Key:6

Our initial shared key:6+7

## Part 2: Messaging

Complete this table with each of your messages. This should 
include the entire conversation - the messages that you sent
and the messages that you received.

(If you used something other than the caesar cipher here, describe what you did)

| Encoded Message | Decoded Message | Key |
| --------------- | --------------- | --- |
| yhzoreybba        lumberloon        13

mhyues aifyg        sneaky goelm      20
                    
tkd spgi vdvvxch    evo dart goggins  15

evo royal giant     evo royal giant   0
                |                 |     |
|                 |                 |     |
|                 |                 |     |
|                 |                 |     |


## Part 3: Connection to TCP/IP Model

### Application Layer: Turn your message into binary

Everything we've done in this activity takes place in the application layer. By the time the message leaves the application
layer, it is encoded in binary. We've been working with text for this activity for convenience, but let's see what the binary
looks like.

Go back to the first encrypted message that you sent (it should be in `rsa_encryption_activity/send/encrypted_message.b64`).

This message is represented as a string of letters, numbers, and symbols. But we know that the real message is in binary.

Select the first six characters from this message and copy them here:yhzore

Using the ASCII table, convert these five characters to binary (if necessary,
include leading zeroes so that each character is 8 bits):


### Transport Layer: Break your message into packets

Assume that each packet can hold two bytes. Fill in the packet information below with the binary values you computed above.

    =========
    Packet 1:

    Source: [Gabe]
    Destination: [JJ]  
    Sequence: 1/3
    Data: [01111001] [01101000]
    =========
    Packet 2:

    Source: [Gabe]
    Destination: [JJ]
    Sequence: 2/3 
    Data: [01111010] [01111010]
    =========
    Packet 3:

    Source: [Gabe]
    Destination: [JJ]
    Sequence: 3/3
    Data: [01110010] [01100101]
    =========

## Part 4: Reflection Questions

- What is the difference between symmetric and asymmetric encryption? What purpose did each serve in this simulation?
Symmetric encryption uses the same key for both encryption and decryption, while asymmetric encryption uses a public key to encrypt and a private key to decrypt. in the simulation, asymmetric encryption securely exchanged keys, and symmetric encryption protected the message content.
- Why is it important that this protocol uses a new key for each message?
Using a new key for each message ensures forward secrecy, so even if one key is compromised, past and future messages remain secure.
- Why is it important that you never share your secret key?
Sharing your secret key would allow others to decrypt your messages or impersonate you, completely undermining your security.
- In the transport layer, do these messages use TCP or UDP? Why?
These messages use TCP because it guarantees reliable, ordered delivery, which is essential for secure communication protocols.
- Now that you've created packets in the transport layer, give a short explanation of what happens to these packets in the internet layer and in the link layer.
In the internet layer, packets are assigned IP addresses and routed across networks, while in the link layer, they are framed with MAC addresses and transmitted over the physical medium.
- This protocol successfully encrypts the **content** of the message. Even though and adversary in the middle can't read the content of the message, what other
Even though the message content is encrypted, an adversary can still see metadata like IP addresses, packet sizes, and timing, which can be used for traffic analysis.
information can they still see?
