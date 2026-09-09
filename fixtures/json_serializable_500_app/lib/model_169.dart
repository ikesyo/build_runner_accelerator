import 'package:json_annotation/json_annotation.dart';

part 'model_169.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model169 {
  const Model169({required this.id, required this.value});

  final int id;
  final String value;

  factory Model169.fromJson(Map<String, dynamic> json) =>
      _$Model169FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model169ToJson(this);
}
