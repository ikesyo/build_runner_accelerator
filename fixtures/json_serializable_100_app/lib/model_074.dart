import 'package:json_annotation/json_annotation.dart';

part 'model_074.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model074 {
  const Model074({required this.id, required this.value});

  final int id;
  final String value;

  factory Model074.fromJson(Map<String, dynamic> json) =>
      _$Model074FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model074ToJson(this);
}
