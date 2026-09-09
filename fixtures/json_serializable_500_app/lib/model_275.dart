import 'package:json_annotation/json_annotation.dart';

part 'model_275.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model275 {
  const Model275({required this.id, required this.value});

  final int id;
  final String value;

  factory Model275.fromJson(Map<String, dynamic> json) =>
      _$Model275FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model275ToJson(this);
}
