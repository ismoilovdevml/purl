import { mount } from 'svelte';
import App from './App.svelte';
// variables.css first: it declares the design tokens every other stylesheet
// and every component references bare, with no fallback literal.
import './styles/variables.css';
import './styles/animations.css';
import './styles/focus.css';

const app = mount(App, {
  target: document.getElementById('app'),
});

export default app;
