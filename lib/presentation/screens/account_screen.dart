import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/auth_repository.dart';
import '../../domain/account_service.dart';
import '../format.dart';
import '../providers.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured = ref.watch(syncConfiguredProvider);
    final account = ref.watch(accountProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: !configured
          ? const _NotConfigured()
          : switch (account) {
              AsyncData(value: final a?) => _SignedIn(account: a),
              AsyncData() => const _SignInForm(),
              AsyncError(:final error) => Center(child: Text('$error')),
              _ => const Center(child: CircularProgressIndicator()),
            },
    );
  }
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Text(
      'Sync is not set up in this build, so tasks stay on this device.\n\n'
      'To enable it, put SUPABASE_URL and SUPABASE_ANON_KEY in .env and run '
      'with --dart-define-from-file=.env.',
    ),
  );
}

// ------------------------------------------------------------- signed in

class _SignedIn extends ConsumerStatefulWidget {
  const _SignedIn({required this.account});

  final Account account;

  @override
  ConsumerState<_SignedIn> createState() => _SignedInState();
}

class _SignedInState extends ConsumerState<_SignedIn> {
  var _busy = false;

  Future<void> _signOut() async {
    final service = ref.read(accountServiceProvider);
    if (service == null) return;
    final result = await _busyWhile(service.signOut);
    if (result case UnsyncedChangesBlockSignOut(:final changes)) {
      if (!mounted) return;
      final discard = await confirmDiscardUnsynced(context, changes);
      if (!discard) return;
      final confirmed = await _busyWhile(
        () => service.signOut(discardUnsynced: true),
      );
      if (confirmed == null) return;
    } else if (result == null) {
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// Runs [action] with the button in its busy state; null if it failed (the
  /// error is shown). Not busy while the confirmation dialog is open.
  Future<SignOutResult?> _busyWhile(
    Future<SignOutResult> Function() action,
  ) async {
    setState(() => _busy = true);
    try {
      return await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't sign out: $e")));
      }
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncStatusProvider).value;
    final pending = ref.watch(pendingCountProvider).value ?? 0;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: const Icon(Icons.account_circle, size: 40),
          title: Text(widget.account.email ?? 'Signed in'),
          subtitle: const Text(
            'Tasks sync to every device signed in to this account.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.sync),
          title: Text(
            status?.lastSyncAt == null
                ? 'Not synced yet in this session'
                : 'Last synced ${formatAgo(status!.lastSyncAt!)}',
          ),
          subtitle: Text(
            pending == 0
                ? 'No changes waiting'
                : '$pending ${pending == 1 ? 'change' : 'changes'} waiting to sync',
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          key: const Key('sign-out'),
          onPressed: _busy ? null : _signOut,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.logout),
          label: Text(_busy ? 'Syncing before sign-out…' : 'Sign out'),
        ),
        const SizedBox(height: 8),
        Text(
          'Signing out removes the tasks from this device. They stay in your '
          'account.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Asks before throwing away changes that never reached the server. Cancel is
/// the default (focused, and what dismissing the dialog means).
Future<bool> confirmDiscardUnsynced(
  BuildContext context,
  List<UnsyncedChange> changes,
) async {
  final n = changes.length;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.warning_amber),
      title: Text('$n unsynced ${n == 1 ? 'change' : 'changes'} will be lost'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "These haven't reached the server, and signing out deletes "
              'them from this device:',
            ),
            const SizedBox(height: 8),
            for (final c in changes.take(8))
              Text(
                '• ${c.title}${c.failed ? ' (failed: ${c.lastError})' : ''}',
              ),
            if (n > 8) Text('…and ${n - 8} more'),
            const SizedBox(height: 8),
            const Text('Cancel, go online, and sign out again to keep them.'),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const Key('cancel-sign-out'),
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('confirm-discard'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Sign out and discard'),
        ),
      ],
    ),
  );
  return result ?? false;
}

// ------------------------------------------------------------ signed out

class _SignInForm extends ConsumerStatefulWidget {
  const _SignInForm();

  @override
  ConsumerState<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends ConsumerState<_SignInForm> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _creating = false;
  var _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final auth = ref.read(authRepositoryProvider);
    if (auth == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      if (_creating) {
        final outcome = await auth.signUp(
          email: _email.text,
          password: _password.text,
        );
        if (outcome == SignUpOutcome.confirmEmail) {
          setState(() {
            _info = 'Check your email to confirm the account, then sign in.';
            _creating = false;
          });
          return;
        }
      } else {
        await auth.signIn(email: _email.text, password: _password.text);
      }
      if (mounted) Navigator.of(context).pop();
    } on AuthFailure catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            _creating ? 'Create an account' : 'Sign in',
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Your tasks are backed up and synced to every device you sign in '
            'on. Tasks you already made on this device are uploaded too.',
          ),
          const SizedBox(height: 24),
          TextFormField(
            key: const Key('email-field'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
            validator: (v) => (v == null || !v.contains('@'))
                ? 'Enter your email address'
                : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('password-field'),
            controller: _password,
            obscureText: true,
            autofillHints: [
              _creating ? AutofillHints.newPassword : AutofillHints.password,
            ],
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                (v == null || v.length < 6) ? 'At least 6 characters' : null,
            onFieldSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (_info != null) ...[const SizedBox(height: 12), Text(_info!)],
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('submit-auth'),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_creating ? 'Create account' : 'Sign in'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _creating = !_creating;
                    _error = null;
                  }),
            child: Text(
              _creating
                  ? 'I already have an account'
                  : "New here? Create an account",
            ),
          ),
        ],
      ),
    );
  }
}
