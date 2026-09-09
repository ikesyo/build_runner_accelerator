import 'package:json_annotation/json_annotation.dart';

part 'model_315.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model315 {
  const Model315({required this.id, required this.value});

  final int id;
  final String value;

  factory Model315.fromJson(Map<String, dynamic> json) =>
      _$Model315FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model315ToJson(this);
}
