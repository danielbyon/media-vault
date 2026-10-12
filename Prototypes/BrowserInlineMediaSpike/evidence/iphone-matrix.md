# iPhone 17 (iOS 27) inline-media observations

SwiftUI `.webViewContextMenu` is unavailable on iOS 27 in the installed SDK. Menu accessibility does not imply an app callback or a selected URL.

| Mode | Case | Fixture media GETs | Native menu seen | Native callback | Menu labels | JS contextmenu | Diagnostic touch/pointer | Selected media | Link destination | Native frame | Frame request | Rejections |
| --- | --- | --- | --- | --- | --- | ---: | ---: | --- | --- | --- | --- | --- |
| bridge | linked-image | /media/image-a.jpg | true | unavailable on iOS 27 | Save to Photos,Share…,Open Link,Add to Reading List | 0 | 0 | absent | absent | absent | absent | none |
| bridge | unlinked-image | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| bridge | picture | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| bridge | video-src | /media/image-a.jpg, /media/video-a.mp4 | false | unavailable on iOS 27 |  | 0 | 0 | absent | absent | absent | absent | none |
| bridge | video-source | /media/image-a.jpg, /media/video-a.mp4 | false | unavailable on iOS 27 |  | 0 | 0 | absent | absent | absent | absent | none |
| bridge | css-background | /media/image-a.jpg | false | unavailable on iOS 27 |  | 0 | 0 | absent | absent | absent | absent | none |
| bridge | canvas | none | false | unavailable on iOS 27 |  | 0 | 0 | absent | absent | absent | absent | none |
| bridge | same-iframe | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| bridge | cross-iframe | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| bridge | responsive | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| bridge | relative | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| bridge | dynamic | /media/image-a.jpg, /media/image-b.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| bridge | blob | in-page blob JPEG | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| bridge | data | in-page data JPEG | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| bridge | blob | in-page blob JPEG | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| bridge | data | in-page data JPEG | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| diagnostic | unlinked-image | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 3 | absent | absent | http://127.0.0.1:18755 (main=true) | http://127.0.0.1:18755/case/unlinked-image | none |
| bridge | synthetic | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | synthetic-event |
| bridge | forged-page | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| diagnostic | same-iframe | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 2 | absent | absent | http://127.0.0.1:18755 (main=false) | http://127.0.0.1:18755/frame/same-iframe | none |
| diagnostic | cross-iframe | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 2 | absent | absent | http://localhost:18755 (main=false) | http://localhost:18755/frame/cross-iframe | none |
| diagnostic | video-src | /media/image-a.jpg, /media/video-a.mp4 | false | unavailable on iOS 27 |  | 0 | 2 | absent | absent | http://127.0.0.1:18755 (main=true) | http://127.0.0.1:18755/case/video-src | none |
| diagnostic | video-source | /media/image-a.jpg, /media/video-a.mp4 | false | unavailable on iOS 27 |  | 0 | 2 | absent | absent | http://127.0.0.1:18755 (main=true) | http://127.0.0.1:18755/case/video-source | none |
| native | linked-image | /media/image-a.jpg | true | unavailable on iOS 27 | Save to Photos,Share…,Open Link,Add to Reading List | 0 | 0 | absent | absent | absent | absent | none |
| native | unlinked-image | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| native | picture | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| native | video-src | /media/image-a.jpg, /media/video-a.mp4 | false | unavailable on iOS 27 |  | 0 | 0 | absent | absent | absent | absent | none |
| native | video-source | /media/image-a.jpg, /media/video-a.mp4 | false | unavailable on iOS 27 |  | 0 | 0 | absent | absent | absent | absent | none |
| native | css-background | /media/image-a.jpg | false | unavailable on iOS 27 |  | 0 | 0 | absent | absent | absent | absent | none |
| native | canvas | none | false | unavailable on iOS 27 |  | 0 | 0 | absent | absent | absent | absent | none |
| native | same-iframe | /media/image-a.jpg | true | unavailable on iOS 27 | Copy,Copy Subject,Look Up,Save to Photos,Share… | 0 | 0 | absent | absent | absent | absent | none |
| native | cross-iframe | /media/image-a.jpg | false | unavailable on iOS 27 |  | 0 | 0 | absent | absent | absent | absent | none |

The menu column is an XCUITest accessibility observation after `press(forDuration: 1.1)`. An empty callback/URL column is recorded as unavailable or undelivered, not as a URL-returning callback with no URL.
