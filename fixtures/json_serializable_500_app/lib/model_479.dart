import 'package:json_annotation/json_annotation.dart';

part 'model_479.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model479 {
  const Model479({required this.id, required this.value});

  final int id;
  final String value;

  factory Model479.fromJson(Map<String, dynamic> json) =>
      _$Model479FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model479ToJson(this);
}
