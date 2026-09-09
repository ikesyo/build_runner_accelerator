import 'package:json_annotation/json_annotation.dart';

part 'model_347.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model347 {
  const Model347({required this.id, required this.value});

  final int id;
  final String value;

  factory Model347.fromJson(Map<String, dynamic> json) =>
      _$Model347FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model347ToJson(this);
}
