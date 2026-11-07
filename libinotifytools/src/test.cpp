#include "inotifytools/inotify.h"
#include "inotifytools/inotifytools.h"

#include "../../config.h"

#include <unistd.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

#ifdef HAVE_MCHECK_H
#include <mcheck.h>
#endif

#define verify(A)                                                            \
	if (!_verify((int)(A), #A, __FILE__, __LINE__, __PRETTY_FUNCTION__)) \
		return;
#define verify2(A, B)                                                       \
	if (!_verify((int)(A), B, __FILE__, __LINE__, __PRETTY_FUNCTION__)) \
		return;
#define compare(A, B)                                                       \
	if (!_compare((uintptr_t)(A), (int)(B), #A, #B, __FILE__, __LINE__, \
		      __PRETTY_FUNCTION__))                                 \
		return;

#define succeed()                                                       \
	do {                                                            \
		++tests_succeeded;                                      \
		/*fprintf(stderr, "%s:%d Test '%s' passed", file, line, \
		 * func);*/                                             \
		/*fprintf(stderr, "\n");*/                              \
	} while (0)

#define fail(...)                                                              \
	do {                                                                   \
		++tests_failed;                                                \
		fprintf(stderr, "%s:%d Test '%s' failed: ", file, line, func); \
		fprintf(stderr, __VA_ARGS__);                                  \
		fprintf(stderr, "\n");                                         \
		if (inotifytools_error() != 0) {                               \
			fprintf(stderr,                                        \
				"inotifytools_error() returns %d (%s)\n",      \
				inotifytools_error(),                          \
				strerror(inotifytools_error()));               \
		}                                                              \
	} while (0)

#define TEST_DIR "/tmp/inotifytools_test"

#define INFO(...)                                    \
	do {                                         \
		printf("%s: ", __PRETTY_FUNCTION__); \
		printf(__VA_ARGS__);                 \
	} while (0)

#define ENTER INFO("test begin\n");
#define EXIT INFO("test end\n");

static int tests_failed;
static int tests_succeeded;

int _verify(int cond,
	    char const* teststr,
	    char const* file,
	    int line,
	    char const* func) {
	if (cond) {
		succeed();
		return cond;
	}

	fail("Verification failed (%s)", teststr);
	return cond;
}

int _compare(int value,
	     int expval,
	     char const* act_str,
	     char const* exp_str,
	     char const* file,
	     int line,
	     char const* func) {
	if (value == expval) {
		succeed();
		return 1;
	}

	fail("Actual (%s): %d, Expected (%s): %d", act_str, value, exp_str,
	     expval);
	return 0;
}

void event_to_str() {
	ENTER
	verify2(
	    !strcmp(inotifytools_event_to_str(IN_OPEN | IN_MODIFY | IN_ACCESS),
		    "OPEN,MODIFY,ACCESS") ||
		!strcmp(
		    inotifytools_event_to_str(IN_OPEN | IN_MODIFY | IN_ACCESS),
		    "OPEN,ACCESS,MODIFY") ||
		!strcmp(
		    inotifytools_event_to_str(IN_OPEN | IN_MODIFY | IN_ACCESS),
		    "ACCESS,OPEN,MODIFY") ||
		!strcmp(
		    inotifytools_event_to_str(IN_OPEN | IN_MODIFY | IN_ACCESS),
		    "MODIFY,OPEN,ACCESS") ||
		!strcmp(
		    inotifytools_event_to_str(IN_OPEN | IN_MODIFY | IN_ACCESS),
		    "ACCESS,MODIFY,OPEN") ||
		!strcmp(
		    inotifytools_event_to_str(IN_OPEN | IN_MODIFY | IN_ACCESS),
		    "MODIFY,ACCESS,OPEN"),
	    inotifytools_event_to_str(IN_OPEN | IN_MODIFY | IN_ACCESS));
	EXIT
}

void event_to_str_sep() {
	ENTER
	verify2(!strcmp(inotifytools_event_to_str_sep(
			    IN_OPEN | IN_MODIFY | IN_ACCESS, ':'),
			"OPEN:MODIFY:ACCESS") ||
		    !strcmp(inotifytools_event_to_str_sep(
				IN_OPEN | IN_MODIFY | IN_ACCESS, ':'),
			    "OPEN:ACCESS:MODIFY") ||
		    !strcmp(inotifytools_event_to_str_sep(
				IN_OPEN | IN_MODIFY | IN_ACCESS, ':'),
			    "ACCESS:OPEN:MODIFY") ||
		    !strcmp(inotifytools_event_to_str_sep(
				IN_OPEN | IN_MODIFY | IN_ACCESS, ':'),
			    "MODIFY:OPEN:ACCESS") ||
		    !strcmp(inotifytools_event_to_str_sep(
				IN_OPEN | IN_MODIFY | IN_ACCESS, ':'),
			    "ACCESS:MODIFY:OPEN") ||
		    !strcmp(inotifytools_event_to_str_sep(
				IN_OPEN | IN_MODIFY | IN_ACCESS, ':'),
			    "MODIFY:ACCESS:OPEN"),
		inotifytools_event_to_str_sep(IN_OPEN | IN_MODIFY | IN_ACCESS,
					      ':'));
	EXIT
}

void str_to_event() {
	ENTER
	compare(inotifytools_str_to_event("open,modify,access"),
		IN_OPEN | IN_MODIFY | IN_ACCESS);
	compare(inotifytools_str_to_event(",open,modify,access"), 0);
	compare(inotifytools_str_to_event("open,modify,access,"), 0);
	compare(inotifytools_str_to_event("open,modify,,access,close"), 0);
	compare(inotifytools_str_to_event("open,mod,access,close"), -1);
	compare(inotifytools_str_to_event("mod"), -1);
	compare(inotifytools_str_to_event(","), 0);
	compare(inotifytools_str_to_event(",,"), 0);
	compare(inotifytools_str_to_event("open"), IN_OPEN);
	compare(inotifytools_str_to_event("close"), IN_CLOSE);
	compare(inotifytools_str_to_event(",close"), 0);
	compare(inotifytools_str_to_event(",,close"), 0);
	compare(inotifytools_str_to_event("close,"), 0);
	compare(inotifytools_str_to_event("close,,"), 0);
	EXIT
}

void str_to_event_sep() {
	ENTER
	compare(inotifytools_str_to_event_sep("open:modify:access", ':'),
		IN_OPEN | IN_MODIFY | IN_ACCESS);
	compare(inotifytools_str_to_event_sep("open,modify,access", ','),
		IN_OPEN | IN_MODIFY | IN_ACCESS);
	compare(inotifytools_str_to_event_sep(":open:modify:access", ':'), 0);
	compare(inotifytools_str_to_event_sep("open:modify:access:", ':'), 0);
	compare(inotifytools_str_to_event_sep("open:modify::access:close", ':'),
		0);
	compare(inotifytools_str_to_event_sep("open:mod:access:close", ':'),
		-1);
	compare(inotifytools_str_to_event_sep("mod", ':'), -1);
	compare(inotifytools_str_to_event_sep(":", ':'), 0);
	compare(inotifytools_str_to_event_sep("::", ':'), 0);
	compare(inotifytools_str_to_event_sep("open", ':'), IN_OPEN);
	compare(inotifytools_str_to_event_sep("close", ':'), IN_CLOSE);
	compare(inotifytools_str_to_event_sep(":close", ':'), 0);
	compare(inotifytools_str_to_event_sep("::close", ':'), 0);
	compare(inotifytools_str_to_event_sep("close:", ':'), 0);
	compare(inotifytools_str_to_event_sep("close::", ':'), 0);
	compare(inotifytools_str_to_event_sep("open:modify:access", ','), -1);
	compare(inotifytools_str_to_event_sep("open:modify:access", 'o'), -1);
	EXIT
}

void basic_watch_info() {
	ENTER
	verify(inotifytools_initialize());
	verify(inotifytools_watch_file("/", IN_CLOSE));
	compare(inotifytools_wd_from_filename("/"), 1);
	compare(inotifytools_wd_from_filename("foobar"), -1);
	verify(!strcmp(inotifytools_filename_from_wd(1), "/"));
	verify(inotifytools_remove_watch_by_filename("/"));
	compare(inotifytools_wd_from_filename("/"), -1);
	compare(*inotifytools_filename_from_wd(1), 0);
	verify(inotifytools_watch_file("/", IN_CLOSE));
	compare(inotifytools_wd_from_filename("/"), 2);
	compare(inotifytools_wd_from_filename("foobar"), -1);
	verify(!strcmp(inotifytools_filename_from_wd(2), "/"));
	verify(inotifytools_remove_watch_by_wd(2));
	compare(inotifytools_wd_from_filename("/"), -1);
	compare(*inotifytools_filename_from_wd(2), 0);
	EXIT
}

void tst_inotifytools_snprintf() {
	ENTER
	verify((0 == mkdir(TEST_DIR, 0700)) || (EEXIST == errno));
	verify(inotifytools_initialize());
	verify(inotifytools_watch_file(TEST_DIR, IN_CLOSE));

#define RESET                                                                 \
	do {                                                                  \
		memset(out.buf, 0, MAX_STRLEN);                               \
		memset(test_event, 0, sizeof(struct inotify_event));          \
		test_event->wd = inotifytools_wd_from_filename(TEST_DIR "/"); \
		verify(test_event->wd >= 0);                                  \
		inotifytools_clear_timefmt();                                 \
	} while (0)

	struct nstring out;
	char event_buf[4096];
	struct inotify_event* test_event = (struct inotify_event*)event_buf;

	RESET;
	test_event->mask = IN_ACCESS;
	inotifytools_snprintf(&out, MAX_STRLEN, test_event,
			      "Event %e %.e on %w %f %T");
	verify2(!strcmp(out.buf, "Event ACCESS ACCESS on " TEST_DIR "/  "),
		out.buf);

	RESET;
	test_event->mask = IN_ACCESS | IN_DELETE;
	inotifytools_snprintf(&out, MAX_STRLEN, test_event,
			      "Event %e %.e on %w %f %T");
	verify2(
	    !strcmp(out.buf,
		    "Event ACCESS,DELETE ACCESS.DELETE on " TEST_DIR "/  ") ||
		!strcmp(out.buf,
			"Event DELETE,ACCESS DELETE.ACCESS on " TEST_DIR "/  "),
	    out.buf);

	RESET;
	test_event->mask = IN_MODIFY;
	inotifytools_snprintf(&out, 10, test_event, "Event %e %.e on %w %f %T");
	verify2(!strcmp(out.buf, "Event MODI"), out.buf);

	RESET;
	test_event->mask = IN_ACCESS;
	strncpy(test_event->name, "my_great_file", 14);
	test_event->len = strlen(test_event->name) + 1;
	inotifytools_snprintf(&out, MAX_STRLEN, test_event,
			      "Event %e %.e on %w %f %T");
	verify2(!strcmp(out.buf,
			"Event ACCESS ACCESS on " TEST_DIR "/ my_great_file "),
		out.buf);

	RESET;
	test_event->mask = IN_ACCESS;
	inotifytools_set_printf_timefmt("%D%% %H:%M");
	{
		char expected[MAX_STRLEN];
		char timestr[512];
		time_t now = time(0);
		strftime(timestr, 512, "%D%% %H:%M", localtime(&now));
		snprintf(expected, MAX_STRLEN, "Event ACCESS ACCESS on %s/  %s",
			 TEST_DIR, timestr);
		inotifytools_snprintf(&out, MAX_STRLEN, test_event,
				      "Event %e %.e on %w %f %T");
		verify2(!strcmp(out.buf, expected), out.buf);
	}

	EXIT
}

void watch_limit() {
	ENTER
	verify((0 == mkdir(TEST_DIR, 0700)) || (EEXIST == errno));

	INFO("Warning, this test may take a while\n");
#define INNER_LIMIT 16000
#define OUTER_LIMIT 5

	verify(inotifytools_initialize());
	inotifytools_initialize_stats();

	for (int j = 0; j < OUTER_LIMIT; ++j) {
		char fn[1024];
		int max = 0;
		for (int i = 0; i < INNER_LIMIT; ++i) {
			snprintf(fn, 1023, "%s/%d", TEST_DIR, i);
			int fd = creat(fn, 0700);
			verify(-1 != fd);
			verify(0 == close(fd));
			int ret = inotifytools_watch_file(fn, IN_ALL_EVENTS);
			verify(ret || inotifytools_error() == ENOSPC);
			if (ret) {
				max = i + 1;
				int wd = inotifytools_wd_from_filename(fn);
				verify(wd > 0);
				verify(!strcmp(
				    fn, inotifytools_filename_from_wd(wd)));
			}
		}

		compare(inotifytools_get_num_watches(), max);

		for (int i = 0; i < max; ++i) {
			snprintf(fn, 1023, "%s/%d", TEST_DIR, i);
			verify(inotifytools_remove_watch_by_filename(fn));
		}
	}
	EXIT
}

static void write_close_file(char const* name) {
	char fn[1024];
	snprintf(fn, sizeof(fn), "%s/%s", TEST_DIR, name);
	FILE* f = fopen(fn, "w");
	if (!f) {
		fprintf(stderr, "setup failed, cannot open %s: %s\n", fn,
			strerror(errno));
		exit(EXIT_FAILURE);
	}
	fputs("x", f);
	fclose(f);
}

// A zero timeout call must return in less than this many milliseconds.
static const long PROMPT_MS = 500;
// A one second timeout must not fire before this many milliseconds.
static const long TIMEOUT_MIN_MS = 1000;
// A one second timeout must fire before this many milliseconds.
static const long TIMEOUT_MAX_MS = 3000;

static long elapsed_ms_since(struct timespec const* start) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (long)(now.tv_sec - start->tv_sec) * 1000 +
	       (now.tv_nsec - start->tv_nsec) / 1000000;
}

// Set up a watch on TEST_DIR for IN_CLOSE_WRITE, ignoring files named noise.
#define SETUP_NOISE_FILTER                                                  \
	do {                                                                \
		verify((0 == mkdir(TEST_DIR, 0700)) || (EEXIST == errno));  \
		verify(inotifytools_initialize());                          \
		verify(inotifytools_watch_file(TEST_DIR, IN_CLOSE_WRITE));  \
		verify(inotifytools_ignore_events_by_regex("noise", 0));    \
	} while (0)

// A queued passing event is returned by a zero-timeout call, even
// when a filtered event is queued ahead of it.
void next_events_zero_timeout_passing_after_filtered() {
	ENTER
	SETUP_NOISE_FILTER;
	write_close_file("noise");
	write_close_file("match");

	struct inotify_event* e = inotifytools_next_events(0, 1);
	verify2(e != NULL, "zero timeout must return the queued match event");
	verify2(e->len > 0 && !strcmp(e->name, "match"), e->name);
	EXIT
}

// A filtered event queued between two passing events does not hide the
// second one from a second zero-timeout call.
void next_events_zero_timeout_consecutive_calls() {
	ENTER
	SETUP_NOISE_FILTER;
	write_close_file("match");
	write_close_file("noise");
	write_close_file("match2");

	struct inotify_event* e = inotifytools_next_events(0, 1);
	verify2(e != NULL, "first call must return match");
	verify2(e->len > 0 && !strcmp(e->name, "match"), e->name);

	e = inotifytools_next_events(0, 1);
	verify2(e != NULL, "second call must return match2");
	verify2(e->len > 0 && !strcmp(e->name, "match2"), e->name);
	EXIT
}

// A zero timeout with only filtered events queued returns NULL promptly.
void next_events_zero_timeout_only_filtered() {
	ENTER
	SETUP_NOISE_FILTER;
	write_close_file("noise");
	write_close_file("noise");

	struct timespec start;
	clock_gettime(CLOCK_MONOTONIC, &start);
	struct inotify_event* e = inotifytools_next_events(0, 1);
	long ms = elapsed_ms_since(&start);
	verify2(e == NULL, "only filtered events queued, expected NULL");
	verify2(ms < PROMPT_MS, "zero timeout call did not return promptly");
	EXIT
}

// A zero timeout with nothing queued returns NULL promptly.
void next_events_zero_timeout_nothing_queued() {
	ENTER
	SETUP_NOISE_FILTER;

	struct timespec start;
	clock_gettime(CLOCK_MONOTONIC, &start);
	struct inotify_event* e = inotifytools_next_events(0, 1);
	long ms = elapsed_ms_since(&start);
	verify2(e == NULL, "nothing queued, expected NULL");
	verify2(ms < PROMPT_MS, "zero timeout call did not return promptly");
	EXIT
}

// A timeout of 1 with only filtered events queued returns NULL after
// one to three seconds.
void next_events_timeout_only_filtered() {
	ENTER
	SETUP_NOISE_FILTER;
	write_close_file("noise");
	write_close_file("noise");

	struct timespec start;
	clock_gettime(CLOCK_MONOTONIC, &start);
	struct inotify_event* e = inotifytools_next_events(1, 1);
	long ms = elapsed_ms_since(&start);
	verify2(e == NULL, "only filtered events queued, expected NULL");
	verify2(ms >= TIMEOUT_MIN_MS, "timeout fired early");
	verify2(ms <= TIMEOUT_MAX_MS, "timeout fired late");
	EXIT
}

// Same as the test above, through inotifytools_next_event().
void next_event_timeout_only_filtered() {
	ENTER
	SETUP_NOISE_FILTER;
	write_close_file("noise");
	write_close_file("noise");

	struct timespec start;
	clock_gettime(CLOCK_MONOTONIC, &start);
	struct inotify_event* e = inotifytools_next_event(1);
	long ms = elapsed_ms_since(&start);
	verify2(e == NULL, "only filtered events queued, expected NULL");
	verify2(ms >= TIMEOUT_MIN_MS, "timeout fired early");
	verify2(ms <= TIMEOUT_MAX_MS, "timeout fired late");
	EXIT
}

void cleanup() {
	compare(system("rm -rf " TEST_DIR), 0);
	inotifytools_cleanup();
}

int main() {
	tests_failed = 0;
	tests_succeeded = 0;

#ifdef HAVE_MCHECK_H
	char* mtrace_name = getenv("MALLOC_TRACE");
	if (mtrace_name) {
		printf("malloc trace might be written to %s\n", mtrace_name);
	} else {
		printf(
		    "If you want to do a malloc trace, set MALLOC_TRACE to "
		    "a path for logging.\n");
	}
	mtrace();
#endif

	cleanup();

	event_to_str();
	cleanup();
	event_to_str_sep();
	cleanup();

	str_to_event();
	cleanup();
	str_to_event_sep();
	cleanup();

	basic_watch_info();
	cleanup();

	watch_limit();
	cleanup();

	tst_inotifytools_snprintf();
	cleanup();

	next_events_zero_timeout_passing_after_filtered();
	cleanup();
	next_events_zero_timeout_consecutive_calls();
	cleanup();
	next_events_zero_timeout_only_filtered();
	cleanup();
	next_events_zero_timeout_nothing_queued();
	cleanup();
	next_events_timeout_only_filtered();
	cleanup();
	next_event_timeout_only_filtered();
	cleanup();

	printf("Out of %d tests, %d succeeded and %d failed.\n",
	       tests_failed + tests_succeeded, tests_succeeded, tests_failed);

	if (tests_failed)
		return -tests_failed;
}
