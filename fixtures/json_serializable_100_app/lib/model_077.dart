import 'package:json_annotation/json_annotation.dart';

part 'model_077.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model077 {
  const Model077({required this.id, required this.value});

  final int id;
  final String value;

  factory Model077.fromJson(Map<String, dynamic> json) =>
      _$Model077FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model077ToJson(this);
}
