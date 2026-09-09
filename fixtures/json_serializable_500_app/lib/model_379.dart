import 'package:json_annotation/json_annotation.dart';

part 'model_379.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model379 {
  const Model379({required this.id, required this.value});

  final int id;
  final String value;

  factory Model379.fromJson(Map<String, dynamic> json) =>
      _$Model379FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model379ToJson(this);
}
