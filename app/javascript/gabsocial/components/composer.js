import React from 'react'
import PropTypes from 'prop-types'
import {
  getDefaultKeyBinding,
  Editor,
  EditorState,
  CompositeDecorator,
  RichUtils,
  convertToRaw,
  convertFromRaw,
  ContentState,
} from 'draft-js'
import draftToMarkdown from '../features/ui/util/draft_to_markdown'
import markdownToDraft from '../features/ui/util/markdown_to_draft'
import { urlRegex } from '../features/ui/util/url_regex'
import { CX } from '../constants'
import RichTextEditorBar from './rich_text_editor_bar'

import '!style-loader!css-loader!draft-js/dist/Draft.css'

const markdownOptions = {
  escapeMarkdownCharacters: false,
  preserveNewlines: true,
  remarkablePreset: 'commonmark',
  remarkableOptions: {
    disable: {
      inline: ['links'],
      block: ['table', 'heading'],
    },
    enable: {
      inline: ['del', 'ins'],
    }
  }
}

const getBlockStyle = (block) => {
  switch (block.getType()) {
    case 'blockquote':
      return 'RichEditor-blockquote'
    default:
      return null
  }
}

function groupHandleStrategy(contentBlock, callback, contentState) {
  findWithRegex(GROUP_HANDLE_REGEX, contentBlock, callback)
}

function handleStrategy(contentBlock, callback, contentState) {
  findWithRegex(HANDLE_REGEX, contentBlock, callback)
}

function hashtagStrategy(contentBlock, callback, contentState) {
  findWithRegex(HASHTAG_REGEX, contentBlock, callback)
}

function cashtagStrategy(contentBlock, callback, contentState) {
  findWithRegex(CASHTAG_REGEX, contentBlock, callback)
}

function urlStrategy(contentBlock, callback, contentState) {
  findWithRegex(urlRegex, contentBlock, callback)
}

const findWithRegex = (regex, contentBlock, callback) => {
  const text = contentBlock.getText()
  let matchArr, start
  while ((matchArr = regex.exec(text)) !== null) {
    start = matchArr.index
    callback(start, start + matchArr[0].length)
  }
}

const HighlightedSpan = (props) => {
  return (
    <span
      className={_s.cBrand}
      data-offset-key={props.offsetKey}
    >
      {props.children}
    </span>
  )
}

const compositeDecorator = new CompositeDecorator([
  {
    strategy: handleStrategy,
    component: HighlightedSpan,
  },
  {
    strategy: hashtagStrategy,
    component: HighlightedSpan,
  },
  {
    strategy: cashtagStrategy,
    component: HighlightedSpan,
  },
  {
    strategy: urlStrategy,
    component: HighlightedSpan,
  },
  {
    strategy: groupHandleStrategy,
    component: HighlightedSpan,
  },
])

const styleMap = {
  'CODE': {
    padding: '0.25em 0.5em',
    backgroundColor: 'var(--border_color_secondary)',
    color: 'var(--text_color_secondary)',
    fontSize: 'var(--fs_n)',
  },
};

const GROUP_HANDLE_REGEX = /(?:^|[^\/\)\w])g\/([a-zA-Z]{1,})/g
const HANDLE_REGEX = /\@[\w]+/g
const HASHTAG_REGEX = /\#[\w\u0590-\u05ff]+/g
const CASHTAG_REGEX = /\$[\w\u0590-\u05ff]+/g

class Composer extends React.PureComponent {

  state = {
    active: false,
    editorState: EditorState.createEmpty(compositeDecorator),
    plainText: this.props.value,
  }

  componentDidMount() {
    if (this.props.valueMarkdown && this.props.isPro && this.props.isEdit) {
      const rawData = markdownToDraft(this.props.valueMarkdown, markdownOptions)
      const contentState = convertFromRaw(rawData)
      const editorState = EditorState.createWithContent(contentState)

      this.setState({
        editorState,
        plainText: this.props.value,
      })
    } else if (this.props.value) {
      const editorState = EditorState.push(this.state.editorState, ContentState.createFromText(this.props.value))
      this.setState({
        editorState,
        plainText: this.props.value,
      })
    }
  }

  componentDidUpdate() {
    if (this.state.plainText !== this.props.value) {
      let editorState
      if (!this.props.value) {
        editorState = EditorState.createEmpty(compositeDecorator)
      } else {
        editorState = EditorState.moveFocusToEnd(
          EditorState.push(this.state.editorState, ContentState.createFromText(this.props.value))
        )
      }
      this.setState({
        editorState,
        plainText: this.props.value,
      })
    }
  }

  onChange = (editorState) => {
    const content = editorState.getCurrentContent()
    // const plainText = content.getPlainText('\u0001')

    const blocks = convertToRaw(editorState.getCurrentContent()).blocks
    const value = blocks.map(block => (!block.text.trim() && '') || block.text).join('\n')

    this.setState({
      editorState,
      plainText: value,
    })

    const selectionState = editorState.getSelection()  
    const currentBlockKey = selectionState.getStartKey()
    const currentBlockIndex = blocks.findIndex((k) => k.key === currentBlockKey)
    const priorBlockTextLength = blocks.splice(0, currentBlockIndex).map(block => (!block.text.trim() && '') || block.text).join('\n').length
    const selectionStart = selectionState.getStartOffset()
    const toAdd = currentBlockIndex === 0 ? 0 : 1
    const cursorPosition = priorBlockTextLength + selectionStart + toAdd

    const rawObject = convertToRaw(content)
    const markdownString = this.props.isPro ? draftToMarkdown(rawObject,markdownOptions) : null

    this.props.onChange(null, value, markdownString, cursorPosition)
  }

  handleOnFocus = () => {
    document.addEventListener('paste', this.handleOnPaste)
    this.setState({ active: true })
    this.props.onFocus()
  }

  handleOnBlur = () => {
    document.removeEventListener('paste', this.handleOnPaste, true)
    this.setState({ active: false })
    this.props.onBlur()
  }

  focus = () => {
    this.textbox.focus()
  }

  handleOnPaste = (e) => {
    if (this.state.active) {
      this.props.onPaste(e)
    }
  }

  keyBindingFn = (e) => {
    if (e.type === 'keydown') {
      this.props.onKeyDown(e)
    }

    return getDefaultKeyBinding(e)
  }

  handleKeyCommand = (command) => {
    const { editorState } = this.state
    const newState = RichUtils.handleKeyCommand(editorState, command)

    if (newState) {
      this.onChange(newState)
      return true
    }

    return false
  }

  setRef = (n) => {
    try {
      this.textbox = n
      this.props.inputRef(n) 
    } catch (error) {
      //
    }
  }

  render() {
    const {
      disabled,
      placeholder,
      small,
      isPro,
    } = this.props
    const { editorState } = this.state

    const editorContainerClasses = CX({
      d: 1,
      cursorText: 1,
      text: 1,
      cPrimary: 1,
      fs16PX: !small,
      fs14PX: small,
      pt15: !small,
      px15: !small,
      px10: small,
      pb10: !small,
      h100PC: !small,
    })

    return (
      <div className={[_s.d, _s.flex1].join(' ')}>

        {
          isPro &&
          <RichTextEditorBar
            editorState={editorState}
            onChange={this.onChange}
          />
        }

        <div
          className={editorContainerClasses}
          onClick={this.handleOnFocus}
        >
          <Editor
            blockStyleFn={getBlockStyle}
            editorState={editorState}
            customStyleMap={styleMap}
            handleKeyCommand={this.handleKeyCommand}
            onChange={this.onChange}
            placeholder={placeholder}
            ref={this.setRef}
            readOnly={disabled}
            onBlur={this.handleOnBlur}
            onFocus={this.handleOnFocus}
            keyBindingFn={this.keyBindingFn}
            stripPastedStyles
            spellCheck
          />
        </div>
      </div>
    )
  }

}

Composer.propTypes = {
  inputRef: PropTypes.func,
  disabled: PropTypes.bool,
  placeholder: PropTypes.string,
  value: PropTypes.string,
  valueMarkdown: PropTypes.string,
  onChange: PropTypes.func,
  onKeyDown: PropTypes.func,
  onFocus: PropTypes.func,
  onBlur: PropTypes.func,
  onPaste: PropTypes.func,
  small: PropTypes.bool,
  isPro: PropTypes.bool,
  isEdit: PropTypes.bool,
}

export default Composer