# PlayIntegrityAttestation is optional. Apps that do not use it do not package Play Integrity,
# so R8 must not treat the classes it refers to as missing.
-dontwarn com.google.android.play.core.integrity.**
-dontwarn com.google.android.gms.tasks.**
