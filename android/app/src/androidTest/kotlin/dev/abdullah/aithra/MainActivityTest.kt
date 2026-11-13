package dev.abdullah.aithra

import androidx.test.rule.ActivityTestRule
import dev.flutter.plugins.integration_test.FlutterTestRunner
import org.junit.Rule
import org.junit.runner.RunWith

// Runs the Dart integration test that the build makes the app's entrypoint
// (-Ptarget=integration_test/app_test.dart) and reports each Dart test as a
// JUnit result. FlutterTestRunner launches the activity itself, so the rule
// must not launch it too. The runner finds the rule by reflecting over public
// fields annotated @Rule, hence @JvmField rather than @get:Rule.
@RunWith(FlutterTestRunner::class)
class MainActivityTest {
    @JvmField
    @Rule
    val rule = ActivityTestRule(MainActivity::class.java, true, false)
}
