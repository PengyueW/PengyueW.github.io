# The JavaScript bridge is reached by name from the page, so its methods must keep them.
-keepclassmembers class com.worldbrief.app.WebBridge {
    public *;
}
-keepattributes JavascriptInterface
