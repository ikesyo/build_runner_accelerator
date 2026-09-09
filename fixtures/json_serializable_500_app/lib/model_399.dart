import 'package:json_annotation/json_annotation.dart';

part 'model_399.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model399 {
  const Model399({required this.id, required this.value});

  final int id;
  final String value;

  factory Model399.fromJson(Map<String, dynamic> json) =>
      _$Model399FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model399ToJson(this);
}
